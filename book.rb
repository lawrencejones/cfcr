#!/usr/bin/env ruby

gem "nokogiri"
gem "terminal-table"
gem "colorize"

require "time"
require "json"
require "net/http"
require "nokogiri"
require "terminal-table"
require "colorize"

SCHEDULE_URL = "https://widgets.healcode.com/widgets/schedules/bd269397265.json"

class Schedule
  def self.from_doc(doc)
    dynamic_script = doc.css("script").find do |script|
      script.inner_html.include?("availability")
    end

    lines = dynamic_script.inner_html.lines
    lines.shift until lines.first.include?("scheduleData = {") || lines.empty?

    js_declare = lines.slice(0, 3).join || ""
    js_literal = js_declare.gsub("scheduleData = ", "")

    new(JSON.parse(js_literal).fetch("contents", {}))

  rescue JSON::ParserError
    puts "failed to parse schedule data, continuing without..."
    new({})
  end

  def initialize(data)
    @data = data
  end

  def availability(session_id)
    return unless @data.key?(session_id)

    Nokogiri::HTML(@data[session_id]["classAvailability"]).text
  end
end

response = Net::HTTP.get(URI(SCHEDULE_URL))
contents = JSON.parse(response).fetch("contents")

doc = Nokogiri::HTML(contents)
schedule = Schedule.from_doc(doc)

sessions = doc.css("div.bw-session").map do |session|
  session_info = {
    id: session.attr("data-bw-widget-mbo-class-id"),
    start: Time.parse(
      session.css(".bw-session__time time.hc_starttime").attr("datetime").value,
    ),
    staff: session.css(".bw-session__staff").text.strip,
    place: session.css(".bw-session__location").text.strip,
  }

  session_info[:availability] = schedule.availability(session_info[:id])
  session_info
end

puts Terminal::Table.new(
  headings: sessions.first.keys,
  rows: sessions.sort_by { |session| session.values_at(:place, :start) }.map do |s|
    s[:availability] = s[:availability].colorize(:red) if s[:availability][/waitlist/i]
    s[:start] = s[:start].strftime("%d %a, %H:%M%p").colorize(
      String.colors.select { |c| c[/light/] }[s[:start].wday],
    )

    s.values
  end,
)
