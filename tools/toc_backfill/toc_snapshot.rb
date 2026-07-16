#!/usr/bin/env ruby
# Dumps a snapshot of items.attrs.toc for a list of item IDs
# Usage: ruby toc_snapshot.rb <ids_file>

require 'rubygems'
require 'bundler/setup'

require 'sequel'
require 'json'

def getEnv(name)
  ENV[name] || raise("missing env #{name}")
end

DB = Sequel.connect({
  "adapter"  => "mysql2",
  "host"     => getEnv("ESCHOL_DB_HOST"),
  "port"     => getEnv("ESCHOL_DB_PORT").to_i,
  "database" => getEnv("ESCHOL_DB_DATABASE"),
  "username" => getEnv("ESCHOL_DB_USERNAME"),
  "password" => getEnv("ESCHOL_DB_PASSWORD") })

idsFile = ARGV[0] or raise("Usage: ruby toc_snapshot.rb <ids_file>")
ids = File.readlines(idsFile).map(&:strip).reject(&:empty?)

# Sort by id so before/after files line up for a clean diff
ids.sort.uniq.each { |id|
  row = DB[:items].where(id: id).select(:attrs).first
  attrs = (row && row[:attrs]) ? JSON.parse(row[:attrs]) : {}
  toc = attrs["toc"]

  puts "=== #{id} ==="
  if toc.nil?
    puts "  (no toc)"
  else
    puts "  source: #{toc['source']}"
    (toc['divs'] || []).each { |d|
      loc = d['anchor'] || (d['page'] && "page=#{d['page']}") || "(none)"
      puts "  #{loc}\t#{d['title']}"
    }
  end
  puts
}
