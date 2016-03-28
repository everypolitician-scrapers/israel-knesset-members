#!/bin/env ruby
# encoding: utf-8

require 'scraperwiki'
require 'nokogiri'
require 'open-uri'
require 'colorize'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

@TERMS = {}

class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

def noko_for(url)
  Nokogiri::HTML(open(url).read)
  # Nokogiri::HTML(open(url).read, nil, 'utf-8')
end

def gender_from(icon)
  return if icon.to_s.empty?
  return 'male' if icon == 'MKIconM'
  return 'female' if icon == 'MKIconF'
  raise "Unknown icon: #{icon}"
end

def date_from(str)
  str.split(/[\/\.]/).reverse.map { |e| '%02d' % e.to_i }.join('-')
end

def scrape_letter(let)
  url = 'http://www.knesset.gov.il/mk/eng/mkDetails_eng.asp?letter=%s&view=0' % let
  noko = noko_for(url)
  noko.css('a[href*="mk_individual"]').each do |link|
    id = link.attr('href')[/=(\d+)$/, 1]
    gender_class = link.xpath('../preceding-sibling::td/@class').text
    scrape_person(id, gender_class)
  end
end

# use ID to go directly to print_version
def scrape_person(id, icon)
  url = 'http://www.knesset.gov.il/mk/eng/mk_print_eng.asp?mk_individual_id_t=%s' % id
  noko = noko_for(url)

  person = { 
    id: id,
    name: noko.css('td.EngName').text.tidy,
    image: noko.css('img[src*="/images/members/"]/@src').text.sub('-s.','.'),
    # TODO: some people only have a 'Year of Birth'
    date_of_birth: date_from(noko.xpath('//td[contains(.,"Date of Birth") and not(descendant::td)]/following-sibling::td').text),
    date_of_death: date_from(noko.xpath('//td[contains(.,"Date of Death") and not(descendant::td)]/following-sibling::td').text),
    gender: gender_from(icon),
    source: url,
  }
  person[:image] = URI.join(url, URI.escape(person[:image])).to_s unless person[:image].to_s.empty?

  termtable = noko.xpath('//table[contains(.,"Knesset Terms") and not(descendant::table)]')
  ti = {}
  section = ''
  termtable.css('td').each do |td|
    if td.attr('colspan') == '2'
      section = td.text.tidy
    else
      (ti[section] ||= []) << td.text.tidy
    end
  end
  terms = Hash[*ti['Knesset Terms']]
  groups = Hash[*ti['Parliamentary Groups']] rescue binding.pry

  terms.each do |tname, dates|
    termid = tname.sub('Knesset ','')
    start_date, end_date = dates.sub(' (Partial tenure)','').split(' - ').map { |str| date_from(str) }
    data = person.merge({ 
      term: termid,
      start_date: start_date,
      end_date: end_date,
      # Thanks to @mhl for the regex. TODO: handle group changes
      party: groups[tname].to_s.scan(/\w[^\(\),]* *(?:\(.*?\))?/).last || "Unknown",
    })
    if termid.to_s.empty?
      warn "Empty term data in #{url}"
      next
    end
    ScraperWiki.save_sqlite([:id, :term, :party, :start_date], data)

    (@TERMS[termid] ||= []) << [start_date, end_date]
  end
end

noko_for('http://www.knesset.gov.il/mk/eng/MKDetails_eng.asp').css('td a.EngLetter').map(&:text).each do |let|
  scrape_letter(let)
end

@TERMS.sort_by { |t, _| t.to_i }.each do |t, ds|
  term = { 
    id: t,
    name: "Knesset #{t}",
    start_date: ds.map(&:first).compact.min,
    end_date: ds.map(&:last).compact.max,
  }
  ScraperWiki.save_sqlite([:id], term, 'terms')
end
