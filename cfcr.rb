#!/usr/bin/env ruby

gem "nokogiri"
gem "terminal-table"
gem "colorize"
gem "mechanize"
gem "tty-prompt"

require "time"
require "json"
require "toml"
require "net/http"
require "nokogiri"
require "terminal-table"
require "colorize"
require "mechanize"
require "tty-prompt"
require "pry"

SCHEDULE_URL = "https://widgets.healcode.com/widgets/schedules/bd269397265.json"
MINDBODY_URL = "https://widgets.healcode.com/sites/12715"
CREDENTIALS = TOML.load(File.read(File.expand_path("~/.cfcr.toml")))

class Mindbody
  def self.login
    agent = Mechanize.new
    agent.get("#{MINDBODY_URL}/session/new") do |login_page|
      login_page.form_with(action: /session/) do |form|
        form["mb_client_session[username]"] = CREDENTIALS["username"]
        form["mb_client_session[password]"] = CREDENTIALS["password"]
      end.submit
    end

    new(agent)
  end

  def initialize(agent, url: MINDBODY_URL, credentials: CREDENTIALS)
    @agent = agent
    @url = url
  end

  attr_reader :agent, :url

  # List of booked class ids
  def booked_classes
    @booked_classes ||= begin
      schedule = agent.get("#{url}/client/schedules")
      schedule.css("a.item__cancel").map do |a|
        a.attr("href").split("/").last if a.attr("href")
      end.compact
    end
  end

  # Sadly you can't just add a class using the id
  def add_to_cart(signup_link)
    agent.get(signup_link)
  end

  def checkout
    @booked_classes = nil # invalid our cache
    agent.get("#{url}/cart") do |checkout|
      agent.click(checkout.link_with(text: /Next/i))
    end
  end
end

class CityRoad
  def self.from_widget(response:, mindbody:)
    contents = JSON.parse(response).fetch("contents")
    widget = Nokogiri::HTML(contents)

    new(widget, mindbody)
  end

  def initialize(widget, mindbody)
    @widget = widget
    @mindbody = mindbody
    @schedule_data = extract_schedule_data
    @sessions = extract_sessions
  end

  attr_reader :widget, :mindbody, :schedule_data, :sessions

  def availability(id)
    return unless @schedule_data.key?(id)
    Nokogiri::HTML(@schedule_data[id]["classAvailability"]).text
  end

  def sessions(filter_locations=locations)
    @sessions.
      select  { |session| filter_locations.include?(session[:place]) }.
      sort_by { |session| [session[:place], session[:start]] }
  end

  def locations
    @sessions.map { |session| session[:place] }.uniq
  end

  def booked_classes
    @mindbody.booked_classes
  end

  private

  def extract_sessions
    sessions = widget.css("div.bw-session").map do |session|
      {
        id: session.attr("data-bw-widget-mbo-class-id"),
        staff: session.css(".bw-session__staff").text.strip,
        place: session.css(".bw-session__location").text.strip,
        signup: session.css(".bw-widget__cart_button > button").first&.attr("data-url"),
        start: Time.parse(
          session.css(".bw-session__time time.hc_starttime").attr("datetime").value,
        ),
      }
    end

    sessions.each { |session| session[:availability] = availability(session[:id]) }
    sessions.each_with_object(@mindbody.booked_classes) do |session, booked|
      session[:booked] = booked.include?(session[:id])
    end

    sessions.each(&:freeze)
  end

  def extract_schedule_data
    dynamic_script = widget.css("script").find do |script|
      script.inner_html.include?("availability")
    end

    lines = dynamic_script.inner_html.lines
    lines.shift until lines.first.include?("scheduleData = {") || lines.empty?

    js_declare = lines.slice(0, 3).join || ""
    js_literal = js_declare.gsub("scheduleData = ", "")

    JSON.parse(js_literal).fetch("contents", {})

  rescue JSON::ParserError
    puts "failed to parse schedule data, continuing without..."
    {}
  end
end

def tabulate_sessions(sessions, headings: %i[staff place start availability booked])
  Terminal::Table.new(
    headings: headings,
    rows: sessions.sort_by { |session| session.values_at(:place, :start) }.map do |s|
      s[:availability] = s[:availability].colorize(:red) if s[:availability][/waitlist/i]
      s[:start] = s[:start].strftime("%d %a, %H:%M%p").colorize(
        String.colors.select { |c| c[/light/] }[s[:start].wday],
      )

      s.select { |key, _| headings.include?(key) }.values
    end,
  )
end

def format_session_row(s)
  [
    s[:staff],
    s[:place],
    s[:start].strftime("%d %a, %H:%M%p").colorize(
      String.colors.select { |c| c[/light/] }[s[:start].wday],
    ),
    s[:availability].colorize(s[:availability][/waitlist/] ? :red : :reset),
  ]
end

response, mindbody = [
  Thread.new { |t| Thread.current[:value] = Net::HTTP.get(URI(SCHEDULE_URL)) },
  Thread.new { |t| Thread.current[:value] = Mindbody.login },
].each(&:join).map { |t| t[:value] }

city_road = CityRoad.from_widget(response: response, mindbody: mindbody)

prompt = TTY::Prompt.new(enable_color: true, active_color: :cyan)
locations = prompt.multi_select("Choose class location", city_road.locations)

sessions = city_road.sessions(locations)
book_ids = prompt.multi_select("Select sessions to book") do |menu|
  # menu.default(*city_road.booked_classes)
  sessions.each do |session|
    menu.choice(format_session_row(session).join("\t"), session[:id])
  end
end

sessions.each do |session|
  next unless (book_ids - city_road.booked_classes).include?(session[:id])
  city_road.mindbody.add_to_cart(session[:signup])
end

city_road.mindbody.checkout
