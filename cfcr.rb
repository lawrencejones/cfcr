#!/usr/bin/env ruby

gem "nokogiri"
gem "colorize"
gem "mechanize"
gem "tty-prompt"
gem "values"

require "time"
require "json"
require "toml"
require "net/http"
require "nokogiri"
require "colorize"
require "mechanize"
require "tty-prompt"
require "values"

SCHEDULE_URL = "https://widgets.healcode.com/widgets/schedules/bd269397265.json"
MINDBODY_URL = "https://widgets.healcode.com/sites/12715"
CREDENTIALS = TOML.load(File.read(File.expand_path("~/.cfcr.toml")))

class Mindbody
  # Takes 2s
  def self.login
    agent = Mechanize.new
    agent.get("#{MINDBODY_URL}/session/new", redirect: "/sites/12715/client/schedules") do |login_page|
      schedule_page = login_page.form_with(action: /session/) do |form|
        form["mb_client_session[username]"] = CREDENTIALS["username"]
        form["mb_client_session[password]"] = CREDENTIALS["password"]
      end.submit

      return new(agent).tap { |m| m.booked_classes(schedule_page) }
    end
  end

  def initialize(agent, url: MINDBODY_URL, credentials: CREDENTIALS)
    @agent = agent
    @url = url
  end

  attr_reader :agent, :url

  # List of booked class ids- optinally provide a handle to schedule_page
  def booked_classes(schedule_page = nil)
    @booked_classes ||= begin
      schedule_page ||= agent.get("#{url}/client/schedules")
      schedule_page.css("a.item__cancel").map do |a|
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

class Session < Value.new(:id, :staff, :place, :signup, :start, :availability, :booked)
  def self.tabulate(sessions, prefix: "  ", pad: 2)
    rows = sessions.map(&:to_row)
    widths = rows.each_with_object([]) do |row, ws|
      row.each_with_index { |col, i| ws[i] = [ws[i] || 0, 1 + col.size / pad].max }
    end

    rows.map do |row|
      prefix + row.zip(widths).map { |(col, width)| col.ljust(pad * width) }.join("\t")
    end
  end

  def to_row
    [
      staff,
      place,
      start.strftime("%d %a, %H:%M%p").colorize(
        String.colors.select { |c| c[/light/] }[start.wday],
      ),
      availability.colorize(availability[/waitlist/] ? :red : :reset),
    ]
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
      map     { |session| session.with(booked: booked?(session)) }.
      select  { |session| filter_locations.include?(session.place) }.
      sort_by { |session| [session.place, session.start] }
  end

  def locations
    @sessions.map(&:place).uniq
  end

  def booked_classes
    @mindbody.booked_classes
  end

  def booked?(session)
    @mindbody.booked_classes.include?(session.id)
  end

  private

  def extract_sessions
    sessions = widget.css("div.bw-session").map do |session|
      {
        id: session.attr("data-bw-widget-mbo-class-id"),
        staff: session.css(".bw-session__staff").text.strip,
        place: session.css(".bw-session__location").text.strip,
        signup: session.css(".bw-widget__cart_button > button").first&.attr("data-url"),
        booked: false, # placeholder value
        start: Time.parse(
          session.css(".bw-session__time time.hc_starttime").attr("datetime").value,
        ),
      }
    end

    sessions.each { |session| session[:availability] = availability(session[:id]) }
    sessions.map  { |session| Session.with(session) }
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

class Prompt < TTY::Prompt
  def self.run(&block)
    puts "Logging into mindbody..."
    response, mindbody = [
      Thread.new { |t| Thread.current[:value] = Net::HTTP.get(URI(SCHEDULE_URL)) },
      Thread.new { |t| Thread.current[:value] = Mindbody.login },
    ].each(&:join).map { |t| t[:value] }

    city_road = CityRoad.from_widget(response: response, mindbody: mindbody)
    new(city_road, enable_color: true, active_color: :cyan).instance_eval(&block)
    puts("Goodbye!")
  end

  def initialize(city_road, **kwargs)
    @city_road = city_road
    super(**kwargs)
  end

  attr_reader :city_road

  def display_booked_classes
    puts "You are currently booked into:"
    case city_road.sessions.select(&:booked)
    when -> (ss) { ss.empty? } then puts "No sessions!"
    else
      puts Session.tabulate(city_road.sessions.select(&:booked)).join("\n")
    end
  end

  def ask_for_bookings
    locations = multi_select("Choose class location", city_road.locations)
    sessions = city_road.sessions(locations)

    multi_select("Select sessions to book", echo: false) do |menu|
      sessions = city_road.sessions.reject(&:booked)
      rows = Session.tabulate(sessions)
      sessions.zip(rows).each { |(session, row)| menu.choice(row, session) }
    end
  end
end

Prompt.run do
  loop do
    display_booked_classes
    break unless yes?("Book more classes?")

    to_book = ask_for_bookings
    print("Booking #{to_book.count} sessions...")
    to_book.each do |session|
      city_road.mindbody.add_to_cart(session.signup)
      city_road.mindbody.checkout
      print(".")
    end

    puts(" ✓")
  end
end
