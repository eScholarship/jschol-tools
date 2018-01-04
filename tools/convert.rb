#!/usr/bin/env ruby

# This script converts data from old eScholarship into the new eschol5 database.
#
# The "--units" mode converts the contents of allStruct-eschol5.xml and the
# various brand files into the unit/unitHier/etc tables. It is
# built to be fully incremental.
#
# The "--items" mode converts combined an XTF index dump with the contents of
# UCI metadata files into the items/sections/issues/etc. tables. It is also
# built to be fully incremental.

# Use bundler to keep dependencies local
require 'rubygems'
require 'bundler/setup'

# Run from the right directory (the parent of the tools dir)
Dir.chdir(File.dirname(File.expand_path(File.dirname(__FILE__))))

# Remainder are the requirements for this program
require 'aws-sdk'
require 'date'
require 'digest'
require 'fastimage'
require 'fileutils'
require 'httparty'
require 'json'
require 'logger'
require 'mimemagic'
require 'mimemagic/overlay' # for Office 2007+ formats
require 'mini_magick'
require 'nokogiri'
require 'open3'
require 'pp'
require 'rack'
require 'sequel'
require 'ostruct'
require 'time'
require 'yaml'
require_relative '../util/nailgun.rb'
require_relative '../util/sanitize.rb'
require_relative '../util/xmlutil.rb'

# Max size (in bytes, I think) of a batch to send to AWS CloudSearch.
# According to the docs the absolute limit is 5 megs, so let's back off a
# little bit from that and say 4.5 megs.
MAX_BATCH_SIZE = 4500*1024

# Also, CloudSearch takes a really long time to process huge batches of
# small objects, so limit to 500 per batch.
MAX_BATCH_ITEMS = 500

# Max amount of full text we'll send with any single doc. AWS limit is 1 meg, so let's
# go a little short of that so we've got room for plenty of metadata.
MAX_TEXT_SIZE  = 950*1024

DATA_DIR = "/apps/eschol/erep/data"

TEMP_DIR = "/apps/eschol/eschol5/jschol/tmp"
FileUtils.mkdir_p(TEMP_DIR)

# The main database we're inserting data into
DB = Sequel.connect(YAML.load_file("config/database.yaml"))
$dbMutex = Mutex.new

# Log SQL statements, to aid debugging
#File.exists?('convert.sql_log') and File.delete('convert.sql_log')
#DB.loggers << Logger.new('convert.sql_log')

# The old eschol queue database, from which we can get a list of indexable ARKs
QUEUE_DB = Sequel.connect(YAML.load_file("config/queueDb.yaml"))

# The old stats database, from which we can copy item counts
STATS_DB = Sequel.connect(YAML.load_file("config/statsDb.yaml"))

# Queues for thread coordination
$indexQueue = SizedQueue.new(100)
$batchQueue = SizedQueue.new(1)  # no use getting very far ahead of CloudSearch
$splashQueue = Queue.new

# Mode to force checking of the index digests (useful when indexing algorithm or unit structure changes)
$rescanMode = ARGV.delete('--rescan')

# Mode to process a single item and just print it out (no inserting or batching)
$testMode = ARGV.delete('--test')

# Mode to override up-to-date test
$forceMode = ARGV.delete('--force')
$forceMode and $rescanMode = true

# Mode to skip CloudSearch indexing and just do db updates
$noCloudSearchMode = ARGV.delete('--noCloudSearch')

# For testing only, skip items <= X, where X is like "qt26s1s6d3"
$skipTo = nil
pos = ARGV.index('--skipTo')
if pos
  ARGV.delete_at(pos)
  $skipTo = ARGV.delete_at(pos)
end

# CloudSearch API client
$csClient = Aws::CloudSearchDomain::Client.new(credentials: Aws::InstanceProfileCredentials.new,
  endpoint: YAML.load_file("config/cloudSearch.yaml")["docEndpoint"])

# S3 API client
$s3Config = OpenStruct.new(YAML.load_file("config/s3.yaml"))
$s3Client = Aws::S3::Client.new(credentials: Aws::InstanceProfileCredentials.new, region: $s3Config.region)
$s3Bucket = Aws::S3::Bucket.new($s3Config.bucket, client: $s3Client)

# Caches for speed
$allUnits = nil
$unitAncestors = nil
$issueCoverCache = {}
$issueBuyLinks = Hash[*File.readlines("/apps/eschol/erep/xtf/style/textIndexer/mapping/buyLinks.txt").map { |line|
  line =~ %r{^.*entity=(.*);volume=(.*);issue=(.*)\|(.*?)\s*$} ? ["#{$1}:#{$2}:#{$3}", $4] : [nil, line]
}.flatten]
$issueNumberingCache = {}

# Make puts thread-safe, and prepend each line with the thread it's coming from. While we're at it,
# let's auto-flush the output.
$stdoutMutex = Mutex.new
def puts(*args)
  $stdoutMutex.synchronize {
    Thread.current[:name] and STDOUT.write("[#{Thread.current[:name]}] ")
    super(*args)
    STDOUT.flush
  }
end

###################################################################################################
# Determine the old front-end server to use for thumbnailing
$hostname = `/bin/hostname`.strip
$thumbnailServer = case $hostname
  when 'pub-submit-dev'; 'http://pub-eschol-dev.escholarship.org'
  when 'pub-submit-stg-2a', 'pub-submit-stg-2c'; 'http://pub-eschol-stg.escholarship.org'
  when 'pub-submit-prd-2a', 'pub-submit-prd-2c'; 'http://pub-eschol-prd-alb.escholarship.org'
  else raise("unrecognized host #{hostname}")
end

# Item counts for status updates
$nSkipped = 0
$nUnchanged = 0
$nProcessed = 0
$nTotal = 0

$scrubCount = 0

$discTbl = {"1540" => "Life Sciences",
            "3566" => "Medicine and Health Sciences",
            "3864" => "Physical Sciences and Mathematics",
            "3525" => "Engineering",
            "1965" => "Social and Behavioral Sciences",
            "1481" => "Arts and Humanities",
            "1573" => "Law",
            "3688" => "Business",
            "2932" => "Architecture",
            "3579" => "Education"}

$issueRightsCache = {}

###################################################################################################
# Monkey-patch to nicely ellide strings.
class String
  # https://gist.github.com/1168961
  # remove middle from strings exceeding max length.
  def ellipsize(options={})
    max = options[:max] || 40
    delimiter = options[:delimiter] || "..."
    return self if self.size <= max
    remainder = max - delimiter.size
    offset = remainder / 2
    (self[0,offset + (remainder.odd? ? 1 : 0)].to_s + delimiter + self[-offset,offset].to_s)[0,max].to_s
  end unless defined? ellipsize
end

require_relative './models.rb'
require_relative '../splash/splashGen.rb'

###################################################################################################
# Insert hierarchy links (skipping dupes) for all descendants of the given unit id.
def linkUnit(id, childMap, done)
  childMap[id].each_with_index { |child, idx|
    if !done.include?([id, child])
      UnitHier.create(
        :ancestor_unit => id,
        :unit_id => child,
        :ordering => idx,
        :is_direct => true
      )
      done << [id, child]
    end
    if childMap.include?(child)
      linkUnit(child, childMap, done)
      linkDescendants(id, child, childMap, done)
    end
  }
end

###################################################################################################
# Helper function for linkUnit
def linkDescendants(id, child, childMap, done)
  childMap[child].each { |child2|
    if !done.include?([id, child2])
      #puts "linkDescendants: id=#{id} child2=#{child2}"
      UnitHier.create(
        :ancestor_unit => id,
        :unit_id => child2,
        :ordering => nil,
        :is_direct => false
      )
      done << [id, child2]
    end
    if childMap.include?(child2)
      linkDescendants(id, child2, childMap, done)
    end
  }
end

###################################################################################################
# Upload an asset file to S3 (if not already there), and return the asset ID. Attaches a hash of
# metadata to it.
def putAsset(filePath, metadata)

  # Calculate the sha256 hash, and use it to form the s3 path
  md5sum    = Digest::MD5.file(filePath).hexdigest
  sha256Sum = Digest::SHA256.file(filePath).hexdigest
  s3Path = "#{$s3Config.prefix}/binaries/#{sha256Sum[0,2]}/#{sha256Sum[2,2]}/#{sha256Sum}"

  # If the S3 file is already correct, don't re-upload it.
  obj = $s3Bucket.object(s3Path)
  if !obj.exists? || obj.etag != "\"#{md5sum}\""
    #puts "Uploading #{filePath} to S3."
    obj.put(body: File.new(filePath),
            metadata: metadata.merge({
              original_path: filePath.sub(%r{.*/([^/]+/[^/]+)$}, '\1'), # retain only last directory plus filename
              mime_type: MimeMagic.by_magic(File.open(filePath)).to_s
            }))
    obj.etag == "\"#{md5sum}\"" or raise("S3 returned md5 #{resp.etag.inspect} but we expected #{md5sum.inspect}")
  end

  return sha256Sum
end

###################################################################################################
# Upload an image to S3, and return hash of its attributes. If a block is supplied, it will receive
# the dimensions first, and have a chance to raise exceptions on them.
def putImage(imgPath, &block)
  mimeType = MimeMagic.by_magic(File.open(imgPath))
  if mimeType.subtype == "svg+xml"
    # Special handling for SVG images -- no width/height
    return { asset_id: putAsset(imgPath, {}),
             image_type: mimeType.subtype
           }
  else
    mimeType && mimeType.mediatype == "image" or raise("Non-image file #{imgPath}")
    dims = FastImage.size(imgPath)
    block and block.yield(dims)
    return { asset_id: putAsset(imgPath, { width: dims[0].to_s, height: dims[1].to_s }),
             image_type: mimeType.subtype,
             width: dims[0],
             height: dims[1]
           }
  end
end

###################################################################################################
def convertLogo(unitID, unitType, logoEl)
  # Locate the image reference
  logoImgEl = logoEl && logoEl.at("./div[@id='logoDiv']/img[@src]")
  if !logoImgEl
    if unitType != "campus"
      return {}
    end
    # Default logo for campus
    imgPath = "app/images/logo_#{unitID}.svg"
  else
    imgPath = logoImgEl && "/apps/eschol/erep/xtf/static/#{logoImgEl[:src]}"
    imgPath =~ %r{LOGO_PATH|/$} and return {} # logo never configured
  end
  if !File.file?(imgPath)
    #puts "Warning: Can't find logo image: #{imgPath.inspect}" # who cares
    return {}
  end

  data = putImage(imgPath)
  (logoEl && logoEl.attr('banner') == "single") and data[:is_banner] = true
  return { logo: data }
end

###################################################################################################
def convertBlurb(unitID, blurbEl)
  # Make sure there's a div
  divEl = blurbEl && blurbEl.at("./div")
  divEl or return {}

  # Make sure the HTML conforms to our specs
  html = sanitizeHTML(divEl.inner_html)
  html.length > 0 or return {}
  return { about: html }
end

###################################################################################################
def stripXMLWhitespace(node)
  node.children.each_with_index { |kid, idx|
    if kid.comment?
      kid.remove
    elsif kid.element?
      stripXMLWhitespace(kid)
    elsif kid.text?
      prevIsElement = node.children[idx-1] && node.children[idx-1].element?
      nextIsElement = node.children[idx+1] && node.children[idx+1].element?
      ls = kid.content.lstrip
      if ls != kid.content
        if idx == 0
          if ls.empty?
            kid.remove
            next
          else
            kid.content = ls
          end
        elsif prevIsElement && nextIsElement
          if kid.content.strip.empty?
            kid.remove
            next
          else
            kid.content = " " + kid.content.strip + " "
          end
        else
          kid.content = " " + ls
        end
      end
      rs = kid.content.rstrip
      if rs != kid.content
        if idx == node.children.length - 1
          if rs.empty?
            kid.remove
            next
          else
            kid.content = rs
          end
        else
          kid.content = rs + " "
        end
      end
    end
  }
end

###################################################################################################
def putBrandDownload(entity, filename)
  filePath = "/apps/eschol/erep/xtf/static/brand/#{entity}/#{filename}"
  if !File.exist?(filePath)
    puts "Warning: can't find brand download #{filePath}"
    return nil
  end
  return putAsset(filePath, {})
end

###################################################################################################
def convertBrandDownloadToPage(unitID, navBar, navID, linkName, linkTarget)
  if !(linkTarget =~ %r{/brand/([^/]+)/([^/]+)$})
    puts "Warning: can't parse link to file in brand dir: #{linkTarget}"
    return
  end
  entity, filename = $1, $2
  assetID = putBrandDownload(entity, filename)
  assertID or return

  html = "<p>Please see <a href=\"/assets/#{assetID}\">#{filename}</a></p>"
  html = sanitizeHTML(html)

  slug = linkTarget.sub("\.[^.]+$", "").gsub(/[^\w ]/, '')

  Page.create(unit_id: unitID,
              slug: slug,
              name: linkName,
              title: linkName,
              attrs: JSON.generate({ html: html }))
  navBar << { id: navID, type: "page", slug: slug, name: linkName }
end

###################################################################################################
def convertTables(html)
  html.gsub! %r{<table[^>]*>}i, ""
  html.gsub! %r{</table>}i, ""

  html.gsub! %r{<tr[^>]*>}i, ""
  html.gsub! %r{</tr>}i, "<br/>"

  html.gsub! %r{</(td|th)>\s*<(td|th)[^>]*>}i, " | "
  html.gsub! %r{</?(td|th)[^>]*>}i, ""
  return html
end

###################################################################################################
def convertPage(unitID, navBar, navID, contentDiv, slug, name)
  title = nil
  stripXMLWhitespace(contentDiv)
  if contentDiv.children.empty?
    #puts "Warning: empty page content for page #{slug}" # who cares
    return
  end

  # If content consists of a single <p>, strip it off.
  kid = contentDiv.children[0]
  if contentDiv.children.length == 1 && kid.name =~ /^[pP]$/
    contentDiv = kid
  end

  # If it starts with a heading, grab that.
  kid = contentDiv.children[0]
  if kid.name =~ /^h1|h2|h3|H1|H2|H3$/
    title = kid.inner_html
    kid.remove
  else
    #puts("Warning: no title for page #{slug} #{name.inspect}") # who cares
  end

  # If missing name, use title (or fall back to slug). And vice-versa
  name ||= title || slug
  title ||= name

  # If remaining content consists of a single <p>, strip it off.
  kid = contentDiv.children[0]
  if contentDiv.children.length == 1 && kid.name =~ /^[pP]$/
    contentDiv = kid
  end

  # Cheesy conversion of tables to lists, for now at least
  html = contentDiv.inner_html
  convertTables(html)

  html = sanitizeHTML(html)
  html.length > 0 or return

  # Replace old-style links
  html.gsub!(%r{href="([^"]+)"}) { |m|
    link = $1
    %{href="#{mapEntityLink(link) || link}"}
  }

  Page.create(unit_id: unitID,
              slug: slug,
              name: name,
              title: title ? title : name,
              attrs: JSON.generate({ html: html }))
  navBar << { id: navID, type: "page", slug: slug, name: name }
end

###################################################################################################
def mapEntityLink(linkTarget)
  case linkTarget.sub(%r{^https?://escholarship.org}, '').sub(%r{^[/.]+}, '')
  when %r{^uc/search\?entity=([^;]+)(;view=([^;]+))?}
    "/uc/#{$1}#{$3 && "/#{$3}"}"
  when %r{^uc/search\?entity=([^;]+)(;rmode=[^;]+)?$}
    "/uc/#{$1}"
  when %r{^uc/search\?entity=([^;]+);volume=(\d+);issue=(\d+)$}
    "/uc/#{$1}/#{$2}/#{$3}"
  when %r{^uc/([a-zA-Z0-9_]+)(\?rmode=[^;]+)?$}
    "/uc/#{$1}"
  when %r{^brand/([^/]+)/([^/]+)$}
    entity, filename = $1, $2
    "/uc/#{entity}/#{putBrandDownload(entity, filename)}"
  else
    return nil
  end
end

###################################################################################################
def convertNavBar(unitID, generalEl)
  # Blow away existing database pages for this unit
  Page.where(unit_id: unitID).delete

  navBar = []
  generalEl or return { nav_bar: navBar }

  # Convert each link in linkset
  linkedPagesUsed = Set.new
  aboutBar = nil
  curNavID = 0
  generalEl.xpath("./linkSet/div").each { |linkDiv|
    linkDiv.children.each { |para|
      # First, a bunch of validation checks. We're expecting this kind of thing:
      # <p><a href="http://blah">Link name</a></p>
      para.comment? and next
      if para.text?
        text = para.text.strip
        if !text.empty? and !(para.to_s =~ /--&gt;/)
          puts "Extraneous text in linkSet: #{para}"
        end
        next
      end

      if para.name == "a"
        links = [para]
      elsif para.name != "p"
        puts "Extraneous element in linkSet: #{para}"
        next
      else
        links = para.xpath("./a")
      end

      if links.empty?
        #puts "Missing <a> in linkSet: #{para.inner_html}" # happens for informational headings we strip anyhow
        next
      end
      if links.length > 1
        puts "Too many <a> in linkSet: #{para.inner_html}"
        next
      end

      link = links[0]
      linkName = link.text
      linkName and linkName.strip!
      if !linkName || linkName.empty?
        puts "Missing link text: #{para.inner_html}"
        next
      end

      linkTarget = link.attr('href')
      if !linkTarget && link.attr('onclick') =~ /location.href='([^']+)'/
        linkTarget = $1
      elsif !linkTarget
        puts "Missing link target: #{para.inner_html}"
        next
      end

      if linkTarget =~ /view=(contact|policyStatement|policies|submitPaper|submissionGuidelines)/i
        addTo = navBar
      else
        if !aboutBar
          aboutBar = { id: curNavID+=1, type: "folder", name: "About", sub_nav: [] }
          navBar << aboutBar
        end
        addTo = aboutBar[:sub_nav]
      end

      if linkTarget =~ %r{/uc/search\?entity=[^;]+;view=([^;]+)$}
        slug = $1
        linkedPage = generalEl.at("./linkedPages/div[@id='#{slug}']")
        if !linkedPage
          puts "Can't find linked page #{slug.inspect}"
          next
        end
        convertPage(unitID, addTo, curNavID+=1, linkedPage, slug, linkName)
        linkedPagesUsed << slug
      elsif linkTarget =~ %r{^https?://}
        addTo << { id: curNavID+=1, type: "link", name: linkName, url: linkTarget }
      elsif (mapped = mapEntityLink(linkTarget))
        addTo << { id: curNavID+=1, type: "link", name: linkName, url: mapped }
      elsif linkTarget =~ %r{/brand/}
        convertBrandDownloadToPage(unitID, addTo, curNavID+=1, linkName, linkTarget)
      else
        puts "Invalid link target: #{para.inner_html}"
      end
    }
  }

  # TODO: The "contactInfo" part of the brand file is supposed to end up in the "Journal Information"
  # box at the right side of the eschol UI. Database conversion TBD.
  #convertPage(unitID, navBar, generalEl.at("./contactInfo/div"), "journalInfo", BLAH)

  # Convert unused pages to a hidden bar
  hiddenBar = nil
  generalEl.xpath("./linkedPages/div").each { |page|
    slug = page.attr('id')
    next if slug.nil? || slug.empty?
    next if linkedPagesUsed.include?(slug)
    #puts "Unused linked page, id=#{slug.inspect}" # who cares about the message
    if !hiddenBar
      hiddenBar = { id: curNavID+=1, type: "folder", name: "other pages", hidden: true, sub_nav: [] }
      navBar << hiddenBar
    end
    convertPage(unitID, hiddenBar[:sub_nav], curNavID+=1, page, slug, nil)
  }

  # All done.
  return { nav_bar: navBar }
end

###################################################################################################
def convertSocial(unitID, divs)
  # Hack in some social media for now
  if unitID == "ucla"
    return { twitter: "UCLA", facebook: "uclabruins" }
  elsif unitID == "uclalaw"
   return { twitter: "UCLA_Law", facebook: "pages/UCLA-School-of-Law-Official/148867995080" }
  end

  dataOut = {}
  divs.each { |div|
    next unless div.attr('id') =~ /^(contact|contactUs)$/

    # See if we can find twitter or facebook info
    div.xpath(".//a[@href]").each { |el|
      href = el.attr('href')
      if href =~ %r{^http.*twitter.com/(.*)}
        dataOut[:twitter] = $1
      elsif href =~ %r{^http.*facebook.com/(.*)}
        dataOut[:facebook] = $1
      end
    }
  }
  return dataOut
end

###################################################################################################
def convertDirectSubmit(unitID, el)
  el && el[:url] or return {}

  # Map old page URLs to new
  url = el[:url]
  url =~ %r{/uc/search\?entity=[^;]+;view=([^;]+)$} and url = "/uc/#{unitID}/#{$1}"

  # All done.
  return { directSubmitURL: url }
end

###################################################################################################
def defaultNav(unitID, unitType)
  if unitType == "root"
    return [
      { id: 1, type: "folder", name: "About", sub_nav: [] },
      { id: 2, type: "folder", name: "Campus Sites", sub_nav: [] },
      { id: 3, type: "folder", name: "UC Open Access", sub_nav: [] },
      { id: 4, type: "link", name: "eScholarship Publishing", url: "#" }
    ]
  elsif unitType == "campus"
    return [
      { id: 1, type: "link", name: "Open Access Policies", url: "#" },
      { id: 2, type: "link", name: "Journals", url: "/#{unitID}/journals" },
      { id: 3, type: "link", name: "Academic Units", url: "/#{unitID}/units" }
    ]
  else
    #puts "Warning: no brand file found for unit #{unitID.inspect}" # who cares about msg
    return []
  end
end

###################################################################################################
def convertUnitBrand(unitID, unitType)
  begin
    dataOut = {}

    bfPath = "/apps/eschol/erep/xtf/static/brand/#{unitID}/#{unitID}.xml"
    if File.exist?(bfPath)
      dataIn = fileToXML(bfPath).root
      dataOut.merge!(convertLogo(unitID, unitType, dataIn.at("./display/mainFrame/logo")))
      dataOut.merge!(convertBlurb(unitID, dataIn.at("./display/mainFrame/blurb")))
      if unitType == "campus"
        dataOut.merge!({ nav_bar: defaultNav(unitID, unitType) })
      else
        dataOut.merge!(convertNavBar(unitID, dataIn.at("./display/generalInfo")))
      end
      dataOut.merge!(convertSocial(unitID, dataIn.xpath("./display/generalInfo/linkedPages/div")))
      dataOut.merge!(convertDirectSubmit(unitID, dataIn.at("./directSubmitURL")))
    else
      dataOut.merge!({ nav_bar: defaultNav(unitID, unitType) })
    end

    return dataOut
  rescue
    puts "Error converting brand data for #{unitID.inspect}:"
    raise
  end
end

###################################################################################################
def addDefaultWidgets(unitID, unitType)
  # Blow away existing widgets for this unit
  Widget.where(unit_id: unitID).delete

  widgets = []
  # The following are from the wireframes, but we haven't implemented the widgets yet
  #case unitType
  #  when "root"
  #    widgets << { kind: "FeaturedArticles", region: "sidebar", attrs: nil }
  #    widgets << { kind: "NewJournalIssues", region: "sidebar", attrs: nil }
  #    widgets << { kind: "Tweets", region: "sidebar", attrs: nil }
  #  when "campus"
  #    widgets << { kind: "FeaturedJournals", region: "sidebar", attrs: nil }
  #    widgets << { kind: "Tweets", region: "sidebar", attrs: nil }
  #  else
  #    widgets << { kind: "FeaturedArticles", region: "sidebar", attrs: nil }
  #end
  # So for now, just put RecentArticles on everything.
  widgets << { kind: "RecentArticles", region: "sidebar", attrs: {}.to_json }

  widgets.each_with_index { |widgetInfo, idx|
    Widget.create(unit_id: unitID, ordering: idx+1, **widgetInfo)
  }
end

###################################################################################################
# Convert an allStruct element, and all its child elements, into the database.
def convertUnits(el, parentMap, childMap, allIds, selectedUnits)
  id = el[:id] || el[:ref] || "root"
  allIds << id
  Thread.current[:name] = id.ljust(30)
  #puts "name=#{el.name} id=#{id.inspect} name=#{el[:label].inspect}"

  # Create or update the main database record
  if selectedUnits == "ALL" || selectedUnits.include?(id)
    if el.name != "ptr"
      unitType = id=="root" ? "root" : el[:type]
      # Retain CMS modifications to root and campuses
      if ['root','campus'].include?(unitType) && Unit.where(id: id).first
        #puts "Preserving #{id}."
      else
        selectedUnits == "ALL" or puts "Converting."
        DB.transaction {
          name = id=="root" ? "eScholarship" : el[:label]
          Unit.create_or_update(id,
            type:      unitType,
            name:      name,
            status:    el[:directSubmit] == "moribund" ? "archived" :
                       ["eschol", "all"].include?(el[:hide]) ? "hidden" :
                       "active"
          )

          # We can't totally fill in the brand attributes when initially inserting the record,
          # so do it as an update after inserting.
          attrs = {}
          el[:directSubmit] and attrs[:directSubmit] = el[:directSubmit]
          el[:hide]         and attrs[:hide]         = el[:hide]
          el[:issn]         and attrs[:issn]         = el[:issn]
          attrs.merge!(convertUnitBrand(id, unitType))
          Unit[id].update(attrs: JSON.generate(attrs))

          addDefaultWidgets(id, unitType)
        }
      end
    end
  end

  # Now recursively process the child units
  el.children.each { |child|
    if child.name != "allStruct"
      id or raise("id-less node with children")
      childID = child[:id] || child[:ref]
      childID or raise("id-less child node")
      parentMap[childID] ||= []
      parentMap[childID] << id
      childMap[id] ||= []
      childMap[id] << childID
    end
    convertUnits(child, parentMap, childMap, allIds, selectedUnits)
  }

  # After traversing the whole thing, it's safe to form all the hierarchy links
  if el.name == "allStruct"
    Thread.current[:name] = nil
    if selectedUnits == "ALL"
      DB.transaction {
        # Delete extraneous units from prior conversions
        deleteExtraUnits(allIds)

        puts "Linking units."
        UnitHier.dataset.delete
        linkUnit("root", childMap, Set.new)
      }
    end
  end
end

###################################################################################################
def arkToFile(ark, subpath, root = DATA_DIR)
  shortArk = getShortArk(ark)
  path = "#{root}/13030/pairtree_root/#{shortArk.scan(/\w\w/).join('/')}/#{shortArk}/#{subpath}"
  return path.sub(%r{^/13030}, "13030").gsub(%r{//+}, "/").gsub(/\bbase\b/, shortArk).sub(%r{/+$}, "")
end

###################################################################################################
# Traverse XML, looking for indexable text to add to the buffer.
def traverseText(node, buf)
  return if node['meta'] == "yes" || node['index'] == "no"
  node.text? and buf << node.to_s.strip
  node.children.each { |child| traverseText(child, buf) }
end

###################################################################################################
def grabText(itemID, contentType)
  buf = []
  textCoordsPath = arkToFile(itemID, "rip/base.textCoords.xml")
  htmlPath = arkToFile(itemID, "content/base.html")
  if contentType == "application/pdf" && File.file?(textCoordsPath)
    traverseText(fileToXML(textCoordsPath), buf)
  elsif contentType == "text/html" && File.file?(htmlPath)
    traverseText(fileToXML(htmlPath), buf)
  elsif contentType.nil?
    return ""
  else
    puts "Warning: no text found"
    return ""
  end
  return translateEntities(buf.join("\n"))
end

###################################################################################################
# Empty out an index batch
def emptyBatch(batch)
  batch[:items] = []
  batch[:idxData] = "["
  batch[:idxDataSize] = 0
  return batch
end

###################################################################################################
# Given a list of units, figure out which campus(es), department(s), and journal(s) are responsible.
def traceUnits(units)
  campuses    = Set.new
  departments = Set.new
  journals    = Set.new
  series      = Set.new

  done = Set.new
  units = units.clone   # to avoid trashing the original list
  while !units.empty?
    unitID = units.shift
    if !done.include?(unitID)
      unit = $allUnits[unitID]
      if !unit
        puts "Warning: skipping unknown unit #{unitID.inspect}"
        next
      end
      if unit.type == "journal"
        journals << unitID
      elsif unit.type == "campus"
        campuses << unitID
      elsif unit.type == "oru"
        departments << unitID
      elsif unit.type =~ /series$/
        series << unitID
      end
      units += $unitAncestors[unitID]
    end
  end

  return [campuses.to_a, departments.to_a, journals.to_a, series.to_a]
end

###################################################################################################
def parseDate(str)
  text = str
  text or return nil
  begin
    if text =~ /^([123]\d\d\d)([01]\d)([0123]\d)$/  # handle date missing its dashes
      text = "#{$1}-#{$2}-#{$3}"
    elsif text =~ /^\d\d\d\d$/   # handle data with no month or day
      text = "#{text}-01-01"
    elsif text =~ /^\d\d\d\d-\d\d$/   # handle data with no day
      text = "#{text}-01"
    end
    ret = Date.strptime(text, "%Y-%m-%d")  # throws exception on bad date
    ret.year > 1000 && ret.year < 4000 and return ret.iso8601
  rescue
    begin
      text.sub! /-02-(29|30|31)$/, "-02-28" # Try to fix some crazy dates
      ret = Date.strptime(text, "%Y-%m-%d")  # throws exception on bad date
      ret.year > 1000 && ret.year < 4000 and return ret.iso8601
    rescue
      # pass
    end
  end

  puts "Warning: invalid date: #{str.inspect}"
  return nil
end

###################################################################################################
# Take a UCI author and make it into a string for ease of display.
def formatAuthName(auth)
  str = ""
  fname, lname = auth.text_at("./fname"), auth.text_at("./lname")
  if lname && fname
    str = "#{lname}, #{fname}"
    mname, suffix = auth.text_at("./mname"), auth.text_at("./suffix")
    mname and str += " #{mname}"
    suffix and str += ", #{suffix}"
  elsif fname
    str = fname
  elsif lname
    str = lname
  elsif auth.text_at("./email")  # special case
    str = auth.text_at("./email")
  else
    str = auth.text.strip
    str.empty? and return nil # ignore all-empty author
    puts "Warning: can't figure out author #{auth}"
  end
  return str
end

###################################################################################################
# Try to get fine-grained author info from UCIngest metadata; if not avail, fall back to index data.
def getAuthors(indexMeta, rawMeta)
  # If not UC-Ingest formatted, fall back on index info
  if !rawMeta.at("//authors") && indexMeta
    return indexMeta.multiple("creator").map { |name| {name: name} }
  end

  # For UC-Ingest, we can provide more detailed author info
  rawMeta.xpath("//authors/*").map { |el|
    if el.name == "organization"
      { name: el.text, organization: el.text }
    elsif el.name == "author"
      data = { name: formatAuthName(el) }
      el.children.each { |sub|
        text = sub.text.strip
        next if text.empty?
        data[(sub.name == "identifier") ? (sub.attr('type') + "_id").to_sym : sub.name.to_sym] = text
      }
      data && !data[:name].nil? ? data : nil
    else
      raise("Unknown element #{el.name.inspect} within UCIngest authors")
    end
  }.select{ |v| v }
end

###################################################################################################
def mimeTypeToSummaryType(mimeType)
  if mimeType
    mimeType.mediatype == "audio" and return "audio"
    mimeType.mediatype == "video" and return "video"
    mimeType.mediatype == "image" and return "images"
    mimeType.subtype == "zip" and return "zip"
  end
  return "other files"
end

###################################################################################################
def closeTempFile(file)
  begin
    file.close
    rescue Exception => e
    # ignore
  end
  file.unlink
end

###################################################################################################
def generatePdfThumbnail(itemID, inMeta, existingItem)
  begin
    pdfPath = arkToFile(itemID, "content/base.pdf")
    File.exist?(pdfPath) or return nil
    pdfTimestamp = File.mtime(pdfPath).to_i
    cover = inMeta.at("./content/cover/file[@path]")
    cover and coverPath = arkToFile(itemID, cover[:path])
    if (coverPath and File.exist?(coverPath))
      tempFile0 = Tempfile.new("thumbnail")
      # perform appropriate 90 degree rotation on the image to orient the image for correct viewing 
      MiniMagick::Tool::Convert.new do |convert|
        convert << coverPath 
        convert.auto_orient
        convert << tempFile0.path
      end
      temp1 = MiniMagick::Image.open(tempFile0.path)
      # Resize to 150 pixels wide if bigger than that 
      if (temp1.width > 150)
        temp1.resize (((150.0/temp1.width.to_i).round(4) * 100).to_s + "%")
        tempFile1 = Tempfile.new("thumbnail")
        begin
          temp1.write(tempFile1) 
          data = putImage(tempFile1.path)
        ensure
          closeTempFile(tempFile1)
        end
      else
        data = putImage(coverPath)
      end
      closeTempFile(tempFile0)
      data[:timestamp] = pdfTimestamp
      data[:is_cover] = true
      return data
    else
      existingThumb = existingItem ? JSON.parse(existingItem.attrs)["thumbnail"] : nil
      if existingThumb && existingThumb["timestamp"] == pdfTimestamp
        # Rebuilding to keep order of fields consistent
        return { asset_id:   existingThumb["asset_id"],
                 image_type: existingThumb["image_type"],
                 width:      existingThumb["width"].to_i,
                 height:     existingThumb["height"].to_i,
                 timestamp:  existingThumb["timestamp"].to_i
                }
      end
      # Rip 1st page
      url = "#{$thumbnailServer}/uc/item/#{itemID.sub(/^qt/, '')}?image.view=generateImage;imgWidth=121;pageNum=1"
      response = HTTParty.get(url)
      response.code.to_i == 200 or raise("Error generating thumbnail: HTTP #{response.code}: #{response.message}")
      tempFile2 = Tempfile.new("thumbnail")
      begin
        tempFile2.write(response.body)
        tempFile2.close
        data = putImage(tempFile2.path) { |dims|
          dims[0] == 121 or raise("Got thumbnail width #{dims[0]}, wanted 121")
          dims[1] < 300 or raise("Got thumbnail height #{dims[1]}, wanted less than 300")
        }
        data[:timestamp] = pdfTimestamp
        return data
      ensure
        closeTempFile(tempFile2)
      end
    end
  rescue Exception => e
    puts "Warning: error generating thumbnail: #{e}: #{e.backtrace.join("; ")}"
  end
end

###################################################################################################
# See if we can find a cover image for the given issue. If so, add it to dbAttrs.
def findIssueCover(unit, volume, issue, caption, dbAttrs)
  key = "#{unit}:#{volume}:#{issue}"
  if !$issueCoverCache.key?(key)
    # Check the special directory for a cover image.
    imgPath = "/apps/eschol/erep/xtf/static/issueCovers/#{unit}/#{volume.rjust(2,'0')}_#{issue.rjust(2,'0')}_cover.png"
    data = nil
    if File.exist?(imgPath)
      data = putImage(imgPath)
      caption and data[:caption] = sanitizeHTML(caption)
    end
    $issueCoverCache[key] = data
  end

  $issueCoverCache[key] and dbAttrs['cover'] = $issueCoverCache[key]
end

###################################################################################################
# See if we can find a buy link for this issue, from the table Lisa made.
def addIssueBuyLink(unit, volume, issue, dbAttrs)
  key = "#{unit}:#{volume}:#{issue}"
  link = $issueBuyLinks[key]
  link and dbAttrs[:buy_link] = link
end

###################################################################################################
def addIssueNumberingAttrs(issueUnit, volNum, issueNum, issueAttrs)
  data = $issueNumberingCache[issueUnit]
  if !data
    data = {}
    bfPath = "/apps/eschol/erep/xtf/static/brand/#{issueUnit}/#{issueUnit}.xml"
    if File.exist?(bfPath)
      dataIn = fileToXML(bfPath).root
      el = dataIn.at(".//singleIssue")
      if el && el.text == "yes"
        data[:singleIssue] = true
        data[:startVolume] = dataIn.at("./singleIssue").attr("startVolume")
      end
      el = dataIn.at(".//singleVolume")
      if el && el.text == "yes"
        data[:singleVolume] = true
      end
    end
    $issueNumberingCache[issueUnit] = data
  end

  if data[:singleIssue]
    if data[:startVolume].nil? or volNum.to_i >= data[:startVolume].to_i
      issueAttrs[:numbering] = "volume_only"
    end
  elsif data[:singleVolume]
    issueAttrs[:numbering] = "issue_only"
  end

end

###################################################################################################
def grabUCISupps(rawMeta)
  # For UCIngest format, read supp data from the raw metadata file.
  supps = []
  rawMeta.xpath("//content/supplemental/file").each { |fileEl|
    suppAttrs = { file: fileEl[:path].sub(%r{.*content/supp/}, "") }
    fileEl.children.each { |subEl|
      next if subEl.name == "mimeType" && subEl.text == "unknown"
      suppAttrs[subEl.name] = subEl.text
    }
    supps << suppAttrs
  }
  return supps
end

###################################################################################################
def summarizeSupps(itemID, inSupps)
  outSupps = nil
  suppSummaryTypes = Set.new
  inSupps.each { |supp|
    suppPath = arkToFile(itemID, "content/supp/#{supp[:file]}")
    if !File.exist?(suppPath)
      puts "Warning: can't find supp file #{supp[:file]}"
    else
      # Mime types aren't always reliable coming from Subi. Let's try harder.
      mimeType = MimeMagic.by_magic(File.open(suppPath))
      if mimeType && mimeType.type
        supp.delete("mimeType")  # in case old string-based mimeType is present
        supp[:mimeType] = mimeType.to_s
      end
      suppSummaryTypes << mimeTypeToSummaryType(mimeType)
      (outSupps ||= []) << supp
    end
  }
  return outSupps, suppSummaryTypes
end

###################################################################################################
def translateRights(oldRights)
  case oldRights
    when "cc1"; "CC BY"
    when "cc2"; "CC BY-SA"
    when "cc3"; "CC BY-ND"
    when "cc4"; "CC BY-NC"
    when "cc5"; "CC BY-NC-SA"
    when "cc6"; "CC BY-NC-ND"
    when nil, "public"; nil
    else puts "Unknown rights value #{pf.single("rights").inspect}"
  end
end

###################################################################################################
def isEmbargoed(embargoDate)
  return embargoDate && Date.today < Date.parse(parseDate(embargoDate))
end

###################################################################################################
def shouldSuppressContent(itemID, inMeta)
  # Suppress if withdrawn.
  inMeta.attr("state") == "withdrawn" and return true

  # Supresss if we can't find any of: PDF file, HTML file, supp file, publishedWebLocation.
  inMeta.at("./content/file[@path]") and return false
  inMeta.at("./content/supplemental/file[@path]") and return false
  inMeta.text_at("./context/publishedWebLocation") and return false
  if File.exist?(arkToFile(itemID, "content/base.pdf"))
    #puts "Warning: PDF content file without corresponding content/file metadata"
    return false
  end

  puts "Warning: content-free item"
  return true
end

###################################################################################################
def parseDataAvail(inMeta, attrs)
  el = inMeta.at("./content/supplemental/dataStatement")
  el or return
  ds = { type: el[:type] }
  if el.text && !el.text.strip.empty?
    if el[:type] == "publicRepo"
      ds[:url] = el.text.strip
    elsif el[:type] == "notAvail"
      ds[:reason] = el.text.strip
    elsif el[:type] == "thirdParty"
      ds[:contact] = el.text.strip
    end
  end
  attrs[:data_avail_stmnt] = ds
end

###################################################################################################
def addMerrittPaths(itemID, attrs)
  feed = fileToXML(arkToFile(itemID, "meta/base.feed.xml"))
  feed.remove_namespaces!
  feed = feed.root

  # First, find the path of the main PDF content file
  pdfSize = File.size(arkToFile(itemID, "content/base.pdf")) or raise
  pdfFound = false
  feed.xpath("//link").each { |link|
    if link[:rel] == "http://purl.org/dc/terms/hasPart" &&
         link[:type] == "application/pdf" &&
         link[:length].to_i == pdfSize &&
         link[:title] =~ %r{^producer/}
      attrs[:content_merritt_path] = link[:title]
      pdfFound = true
      break
    end
  }
  pdfFound or puts "Warning: can't find merritt path for pdf"

  # Then do any supp files
  attrs[:supp_files] and attrs[:supp_files].each { |supp|
    suppName = supp[:file]
    suppSize = File.size(arkToFile(itemID, "content/supp/#{suppName}")) or raise
    suppFound = false
    feed.xpath("//link").each { |link|
      if link[:rel] == "http://purl.org/dc/terms/hasPart" &&
           link[:length].to_i == suppSize &&
           link[:title].gsub(/[^\w]/, '').include?(suppName.gsub(/[^\w]/, ''))
        supp[:merritt_path] = link[:title]
        suppFound = true
        break
      end
    }
    suppFound or puts "Warning: can't find merritt path for supp #{suppName}"
  }
end

###################################################################################################
# If an issue's rights have been overridden in eschol5, be sure to prefer that. Likewise, if there's
# a default, take that instead. Failing that, use the most recent issue. If there isn't one, use
# whatever eschol5 came up with.
def checkRightsOverride(unitID, volNum, issNum, oldRights)
  key = "#{unitID}|#{volNum}|#{issNum}"
  if !$issueRightsCache.key?(key)
    # First, check for existing issue rights
    iss = Issue.where(unit_id: unitID, volume: volNum, issue: issNum).first
    if iss
      issAttrs = (iss.attrs && JSON.parse(iss.attrs)) || {}
      rights = issAttrs["rights"]
    else
      # Failing that, check for a default set on the unit
      unit = $allUnits[unitID]
      unitAttrs = unit && unit.attrs && JSON.parse(unit.attrs) || {}
      if unitAttrs["default_issue"] && unitAttrs["default_issue"]["rights"]
        rights = unitAttrs["default_issue"]["rights"]
      else
        # Failing that, use values from the most-recent issue
        iss = Issue.where(unit_id: unitID).order(Sequel.desc(:pub_date)).order_append(Sequel.desc(:issue)).first
        if iss
          issAttrs = (iss.attrs && JSON.parse(iss.attrs)) || {}
          rights = issAttrs["rights"]
        else
          # Failing that, just use whatever rights eschol4 came up with.
          rights = oldRights
        end
      end
    end
    $issueRightsCache[key] = rights
  end
  return $issueRightsCache[key]
end

###################################################################################################
def parseUCIngest(itemID, inMeta, fileType)
  attrs = {}
  attrs[:addl_info] = inMeta.html_at("./comments") and sanitizeHTML(inMeta.html_at("./comments"))
  attrs[:author_hide] = !!inMeta.at("./authors[@hideAuthor]")   # Only journal items can have this attribute
  attrs[:bepress_id] = inMeta.text_at("./context/bpid")
  attrs[:buy_link] = inMeta.text_at("./context/buyLink")
  attrs[:custom_citation] = inMeta.text_at("./customCitation")
  attrs[:doi] = inMeta.text_at("./doi")
  attrs[:embargo_date] = parseDate(inMeta[:embargoDate])
  attrs[:is_peer_reviewed] = inMeta[:peerReview] == "yes"
  attrs[:is_undergrad] = inMeta[:underGrad] == "yes"
  attrs[:isbn] = inMeta.text_at("./context/isbn")
  attrs[:language] = inMeta.text_at("./context/language")
  attrs[:local_ids] = inMeta.xpath("./context/localID").map { |el| { type: el[:type], id: el.text } }
  attrs[:orig_citation] = inMeta.text_at("./originalCitation")
  attrs[:pub_web_loc] = inMeta.xpath("./context/publishedWebLocation").map { |el| el.text.strip }
  attrs[:publisher] = inMeta.text_at("./publisher")
  attrs[:submission_date] = parseDate(inMeta.text_at("./history/submissionDate")) ||
                            parseDate(inMeta[:dateStamp])
  attrs[:suppress_content] = shouldSuppressContent(itemID, inMeta)


  # Normalize language codes
  attrs[:language] and attrs[:language] = attrs[:language].sub("english", "en").sub("german", "de").
                                                           sub("french", "fr").sub("spanish", "es")

  # Set disableDownload flag based on content file
  tmp = inMeta.at("./content/file[@disableDownload]")
  tmp && tmp = parseDate(tmp[:disableDownload]) and attrs[:disable_download] = tmp

  if inMeta[:state] == "withdrawn"
    tmp = inMeta.at("./history/stateChange[@state='withdrawn']")
    tmp and attrs[:withdrawn_date] = tmp[:date].sub(/T.+$/, "")
    if !attrs[:withdrawn_date]
      puts "Warning: no withdraw date found; using stateDate."
      attrs[:withdrawn_date] = inMeta[:stateDate]
    end
    msg = inMeta.text_at("./history/stateChange[@state='withdrawn']/comment")
    msg and attrs[:withdrawn_message] = msg
  end

  # Filter out "n/a" abstracts
  abstract = inMeta.html_at("./abstract")
  abstract and abstract = sanitizeHTML(abstract)
  abstract && abstract.size > 3 and attrs[:abstract] = abstract

  # Disciplines are a little extra work; we want to transform numeric IDs to plain old labels
  attrs[:disciplines] = inMeta.xpath("./disciplines/discipline").map { |discEl|
    discID = discEl[:id]
    if discID == "" && discEl.text && discEl.text.strip && $discTbl.values.include?(discEl.text.strip)
      # Kludge for old <disciplines> with no ID but with exact text
      label = discEl.text.strip
    else
      discID and discID.sub!(/^disc/, "")
      label = $discTbl[discID]
    end
    if !label
      puts("Warning: unknown discipline ID #{discID.inspect}")
      puts "uci: discEl=#{discEl}"
      puts "uci: discTbl=#{$discTbl}" # FIXME FOO
    end
    label
  }.select { |v| v }

  # Supplemental files
  attrs[:supp_files], suppSummaryTypes = summarizeSupps(itemID, grabUCISupps(inMeta))

  # Data availability statement
  parseDataAvail(inMeta, attrs)

  # We'll need this in a couple places later on
  rights = translateRights(inMeta.text_at("./rights"))

  # For eschol journals, populate the issue and section models.
  issue = section = nil
  volNum = inMeta.text_at("./context/volume")
  issueNum = inMeta.text_at("./context/issue")
  if issueNum or volNum
    issueUnit = inMeta.xpath("./context/entity[@id]").select {
                      |ent| $allUnits[ent[:id]] && $allUnits[ent[:id]].type == "journal" }[0]
    issueUnit and issueUnit = issueUnit[:id]
    if issueUnit
      # Data for eScholarship journals
      if $allUnits.include?(issueUnit)
        volNum.nil? and raise("missing volume number on eschol journal item")

        # Prefer eschol5 rights overrides to eschol4.
        rights = checkRightsOverride(issueUnit, volNum, issueNum, rights)

        issue = Issue.new
        issue[:unit_id]  = issueUnit
        issue[:volume]   = volNum
        issue[:issue]    = issueNum
        if inMeta.text_at("./context/issueDate") == "0"  # hack for westjem AIP
          issue[:pub_date] = parseDate(inMeta.text_at("./history/originalPublicationDate") ||
                                       inMeta.text_at("./history/escholPublicationDate") ||
                                       inMeta[:dateStamp])
        else
          issue[:pub_date] = parseDate(inMeta.text_at("./context/issueDate") ||
                                       inMeta.text_at("./history/originalPublicationDate") ||
                                       inMeta.text_at("./history/escholPublicationDate") ||
                                       inMeta[:dateStamp])
        end
        issueAttrs = {}
        tmp = inMeta.text_at("/record/context/issueTitle")
        tmp and issueAttrs[:title] = tmp
        tmp = inMeta.text_at("/record/context/issueDescription")
        tmp and issueAttrs[:description] = tmp
        tmp = inMeta.text_at("/record/context/issueCoverCaption")
        findIssueCover(issueUnit, volNum, issueNum, tmp, issueAttrs)
        addIssueBuyLink(issueUnit, volNum, issueNum, issueAttrs)
        addIssueNumberingAttrs(issueUnit, volNum, issueNum, issueAttrs)
        rights and issueAttrs[:rights] = rights
        !issueAttrs.empty? and issue[:attrs] = issueAttrs.to_json

        section = Section.new
        section[:name] = inMeta.text_at("./context/sectionHeader") || "Articles"
        ord = inMeta.text_at("./context/publicationOrder").to_i
        section[:ordering] = ord > 0 ? ord : nil
      else
        "Warning: issue associated with unknown unit #{issueUnit.inspect}"
      end
    else
      # Data for external journals
      exAtts = {}
      exAtts[:name] = inMeta.text_at("./context/journal")
      exAtts[:volume] = inMeta.text_at("./context/volume")
      exAtts[:issue] = inMeta.text_at("./context/issue")
      exAtts[:issn] = inMeta.text_at("./context/issn")
      exAtts[:fpage] = inMeta.text_at("./extent/fpage")
      exAtts[:lpage] = inMeta.text_at("./extent/lpage")
      exAtts.reject! { |k, v| !v }
      exAtts.empty? or attrs[:ext_journal] = exAtts
    end
  end

  # Generate thumbnails (but only for non-suppressed PDF items)
  if !attrs[:suppress_content] && File.exist?(arkToFile(itemID, "content/base.pdf"))
    attrs[:thumbnail] = generatePdfThumbnail(itemID, inMeta, Item[itemID])
  end

  # Remove empty attrs
  attrs.reject! { |k, v| !v || (v.respond_to?(:empty?) && v.empty?) }

  # Detect HTML-formatted items
  contentFile = inMeta.at("/record/content/file")
  contentFile && contentFile.at("./native") and contentFile = contentFile.at("./native")
  contentPath = contentFile && contentFile[:path]
  contentType = contentFile && contentFile.at("./mimeType") && contentFile.at("./mimeType").text

  # For ETDs (all in Merritt), figure out the PDF path in the feed file
  pdfPath = arkToFile(itemID, "content/base.pdf")
  pdfExists = File.file?(pdfPath)
  if pdfExists
    if fileType == "ETD" && pdfExists
      addMerrittPaths(itemID, attrs)
    end
    attrs[:content_length] = File.size(pdfPath)
  end

  # Populate the Item model instance
  dbItem = Item.new
  dbItem[:id]           = itemID
  dbItem[:source]       = inMeta.text_at("./source") or raise("no source found")
  dbItem[:status]       = attrs[:withdrawn_date] ? "withdrawn" :
                          isEmbargoed(attrs[:embargo_date]) ? "embargoed" :
                          (inMeta[:state] || raise("no state in record"))
  dbItem[:title]        = sanitizeHTML(inMeta.html_at("./title"))
  dbItem[:content_type] = attrs[:suppress_content] ? nil :
                          attrs[:withdrawn_date] ? nil :
                          isEmbargoed(attrs[:embargo_date]) ? nil :
                          inMeta[:type] == "non-textual" ? nil :
                          pdfExists ? "application/pdf" :
                          contentType && contentType.strip.length > 0 ? contentType :
                          nil
  dbItem[:genre]        = (!attrs[:suppress_content] &&
                           dbItem[:content_type].nil? &&
                           attrs[:supp_files]) ? "multimedia" :
                          fileType == "ETD" ? "dissertation" :
                          inMeta[:type] ? inMeta[:type].sub("paper", "article") :
                          "article"
  dbItem[:eschol_date]  = parseDate(inMeta.text_at("./history/escholPublicationDate")) ||
                          parseDate(inMeta[:dateStamp])
  dbItem[:pub_date]     = parseDate(inMeta.text_at("./history/originalPublicationDate")) ||
                          dbItem[:eschol_date]
  dbItem[:attrs]        = JSON.generate(attrs)
  dbItem[:rights]       = rights
  dbItem[:ordering_in_sect] = inMeta.text_at("./context/publicationOrder")

  # Populate ItemAuthor model instances
  authors = getAuthors(nil, inMeta)

  # Make a list of all the units this item belongs to
  units = inMeta.xpath("./context/entity[@id]").map { |ent| ent[:id] }.select { |unitID|
    unitID =~ /^(postprints|demo-journal|test-journal|unknown|withdrawn|uciem_westjem_aip)$/ ? false :
      !$allUnits.include?(unitID) ? (puts("Warning: unknown unit #{unitID.inspect}") && false) :
      true
  }

  return dbItem, attrs, authors, units, issue, section, suppSummaryTypes
end

###################################################################################################
def processWithNormalizer(fileType, itemID, metaPath, nailgun)
  normalizer = case fileType
    when "ETD"
      "/apps/eschol/erep/xtf/normalization/etd/normalize_etd.xsl"
    when "BioMed"
      "/apps/eschol/erep/xtf/normalization/biomed/normalize_biomed.xsl"
    when "Springer"
      "/apps/eschol/erep/xtf/normalization/springer/normalize_springer.xsl"
    else
      raise("Unknown normalization type")
  end

  # Run the raw (ProQuest or METS) data through a normalization stylesheet using Saxon via nailgun
  normText = nailgun.call("net.sf.saxon.Transform",
    ["-r", "org.apache.xml.resolver.tools.CatalogResolver",
     "-x", "org.apache.xml.resolver.tools.ResolvingXMLReader",
     "-y", "org.apache.xml.resolver.tools.ResolvingXMLReader",
     metaPath, normalizer])

  # Write it out to a file locally (useful for debugging and validation)
  FileUtils.mkdir_p(arkToFile(itemID, "", "normalized")) # store in local dir
  normFile = arkToFile(itemID, "base.norm.xml", "normalized")
  normXML = stringToXML(normText)
  File.open(normFile, "w") { |io| normXML.write_xml_to(io, indent:3) }

  # Validate using jing.
  ## This was only really useful during development of the normalizers
  #schemaPath = "/apps/eschol/erep/xtf/schema/uci_schema.rnc"
  #validationProbs = nailgun.call("com.thaiopensource.relaxng.util.Driver", ["-c", schemaPath, normFile], true)
  #if !validationProbs.empty?
  #  validationProbs.split("\n").each { |line|
  #    next if line =~ /missing required element "(subject|mimeType)"/ # we don't care
  #    puts line.sub(/.*norm.xml:/, "")
  #  }
  #end

  # And parse the data
  return parseUCIngest(itemID, normXML.root, fileType)
end

###################################################################################################
def addIdxUnits(idxItem, units)
  campuses, departments, journals, series = traceUnits(units)
  campuses.empty?    or idxItem[:fields][:campuses] = campuses
  departments.empty? or idxItem[:fields][:departments] = departments
  journals.empty?    or idxItem[:fields][:journals] = journals
  series.empty?      or idxItem[:fields][:series] = series
end

###################################################################################################
# Extract metadata for an item, and add it to the current index batch.
# Note that we create, but don't yet add, records to our database. We put off really inserting
# into the database until the batch has been successfully processed by AWS.
def indexItem(itemID, timestamp, batch, nailgun)

  # Grab the main metadata file
  metaPath = arkToFile(itemID, "meta/base.meta.xml")
  if !File.exists?(metaPath) || File.size(metaPath) < 50
    puts "Warning: skipping #{itemID} due to missing or truncated meta.xml"
    $nSkipped += 1
    return
  end
  rawMeta = fileToXML(metaPath)
  rawMeta.remove_namespaces!
  rawMeta = rawMeta.root

  existingItem = Item[itemID]

  normalize = nil
  if rawMeta.name =~ /^DISS_submission/ ||
     (rawMeta.name == "mets" && rawMeta.attr("PROFILE") == "http://www.loc.gov/mets/profiles/00000026.html")
    normalize = "ETD"
  elsif rawMeta.name == "mets"
    normalize = "BioMed"
  elsif rawMeta.name == "Publisher"
    normalize = "Springer"
  end

  Thread.current[:name] = "index thread: #{itemID} #{sprintf("%-8s", normalize ? normalize : "UCIngest")}"

  if normalize
    dbItem, attrs, authors, units, issue, section, suppSummaryTypes =
      processWithNormalizer(normalize, itemID, metaPath, nailgun)
  else
    dbItem, attrs, authors, units, issue, section, suppSummaryTypes =
      parseUCIngest(itemID, rawMeta, "UCIngest")
  end

  text = grabText(itemID, dbItem.content_type)

  # Create JSON for the full text index
  idxItem = {
    type:          "add",   # in CloudSearch land this means "add or update"
    id:            itemID,
    fields: {
      title:         dbItem[:title] || "",
      authors:       (authors.length > 1000 ? authors[0,1000] : authors).map { |auth| auth[:name] },
      abstract:      attrs[:abstract] || "",
      type_of_work:  dbItem[:genre],
      disciplines:   attrs[:disciplines] ? attrs[:disciplines] : [""], # only the numeric parts
      peer_reviewed: attrs[:is_peer_reviewed] ? 1 : 0,
      pub_date:      dbItem[:pub_date].to_date.iso8601 + "T00:00:00Z",
      pub_year:      dbItem[:pub_date].year,
      rights:        dbItem[:rights] || "",
      sort_author:   (authors[0] || {name:""})[:name].gsub(/[^\w ]/, '').downcase,
      is_info:       0
    }
  }

  # Determine campus(es), department(s), and journal(s) by tracing the unit connnections.
  addIdxUnits(idxItem, units)

  # Summary of supplemental file types
  suppSummaryTypes.empty? or idxItem[:fields][:supp_file_types] = suppSummaryTypes.to_a

  # Limit text based on size of other fields (so, 1000 authors will mean less text).
  # We have to stay under the overall limit for a CloudSearch record. This problem is
  # a little tricky, since conversion to JSON introduces additional characters, and
  # it's hard to predict how many. So we just use a binary search.
  idxItem[:fields][:text] = text
  if JSON.generate(idxItem).bytesize > MAX_TEXT_SIZE
    idxItem[:fields][:text] = nil
    baseSize = JSON.generate(idxItem).bytesize
    toCut = (0..text.size).bsearch { |cut|
      JSON.generate({text: text[0, text.size - cut]}).bytesize + baseSize < MAX_TEXT_SIZE
    }
    (toCut==0 || toCut.nil?) and raise("Internal error: have to cut something, but toCut=#{toCut.inspect}")
    puts "Note: Keeping only #{text.size - toCut} of #{text.size} text chars."
    idxItem[:fields][:text] = text[0, text.size - toCut]
  end

  # Make sure withdrawn items get deleted from the index
  if attrs[:suppress_content]
    idxItem = {
      type:          "delete",
      id:            itemID
    }
  end

  dbAuthors = authors.each_with_index.map { |data, idx|
    ItemAuthor.new { |auth|
      auth[:item_id] = itemID
      auth[:attrs] = JSON.generate(data)
      auth[:ordering] = idx
    }
  }

  # Calculate digests of the index data and database records
  idxData = JSON.generate(idxItem)
  idxDigest = Digest::MD5.base64digest(idxData)
  dbCombined = {
    dbItem: dbItem.to_hash,
    dbAuthors: dbAuthors.map { |authRecord| authRecord.to_hash },
    dbIssue: issue ? issue.to_hash : nil,
    dbSection: section ? section.to_hash : nil,
    units: units
  }
  dataDigest = Digest::MD5.base64digest(JSON.generate(dbCombined))

  # Add time-varying things into the database item now that we've generated a stable digest.
  dbItem[:last_indexed] = timestamp
  dbItem[:index_digest] = idxDigest
  dbItem[:data_digest] = dataDigest

  dbDataBlock = { dbItem: dbItem, dbAuthors: dbAuthors, dbIssue: issue, dbSection: section, units: units }

  # Single-item debug
  if $testMode
    pp dbCombined
    fooData = idxItem.clone
    fooData[:fields] and fooData[:fields][:text] and fooData[:fields].delete(:text)
    pp fooData
    exit 1
  end

  # If nothing has changed, skip the work of updating this record.

  # Bootstrapping the addition of data digest (temporary)
  # FIXME: Remove this soon
  if existingItem && existingItem[:data_digest].nil?
    existingItem[:index_digest] = idxDigest
  end

  if existingItem && !$forceMode && existingItem[:index_digest] == idxDigest

    # If only the database portion changed, we can safely skip the CloudSearch re-indxing
    if existingItem[:data_digest] != dataDigest
      puts "Changed item. (database change only, search data unchanged)"
      $dbMutex.synchronize {
        DB.transaction do
          updateDbItem(dbDataBlock)
        end
      }
      $nProcessed += 1
      return
    end

    # Nothing changed; just update the timestamp.
    puts "Unchanged item."
    existingItem.last_indexed = timestamp
    existingItem.save
    $nUnchanged += 1
    return
  end

  puts "#{existingItem ? 'Changed' : 'New'} item.#{attrs[:suppress_content] ? " (suppressed content)" : ""}"

  # Make doubly sure the logic above didn't generate a record that's too big.
  if idxData.bytesize >= 1024*1024
    puts "idxData=\n#{idxData}\n\nInternal error: generated record that's too big."
    exit 1
  end

  # If this item won't fit in the current batch, send the current batch off and clear it.
  if batch[:idxDataSize] + idxData.bytesize > MAX_BATCH_SIZE || batch[:items].length > MAX_BATCH_ITEMS
    #puts "Prepared batch: nItems=#{batch[:items].length} size=#{batch[:idxDataSize]} "
    batch[:items].empty? or $batchQueue << batch.clone
    emptyBatch(batch)
  end

  # Now add this item to the batch
  batch[:items].empty? or batch[:idxData] << ",\n"  # Separator between records
  batch[:idxData] << idxData
  batch[:idxDataSize] += idxData.bytesize
  batch[:items] << dbDataBlock
  #puts "current batch size: #{batch[:idxDataSize]}"

end

###################################################################################################
# Index all the items in our queue
def indexAllItems
  begin
    Thread.current[:name] = "index thread"  # label all stdout from this thread
    batch = emptyBatch({})

    # The resolver and catalog stuff below is to prevent BioMed files from loading external DTDs
    # (which is not only slow but also unreliable)
    classPath = "/apps/eschol/erep/xtf/WEB-INF/lib/saxonb-8.9.jar:" +
                "/apps/eschol/erep/xtf/control/xsl/jing.jar:" +
                "/apps/eschol/erep/xtf/normalization/resolver.jar"
    Nailgun.run(classPath, 0, "-Dxml.catalog.files=/apps/eschol/erep/xtf/normalization/catalog.xml") { |nailgun|
      loop do
        # Grab an item from the input queue
        Thread.current[:name] = "index thread"  # label all stdout from this thread
        itemID, timestamp = $indexQueue.pop
        itemID or break

        # Extract data and index it (in batches)
        begin
          Thread.current[:name] = "index thread: #{itemID}"  # label all stdout from this thread
          indexItem(itemID, timestamp, batch, nailgun)
        rescue Exception => e
          puts "Error indexing item #{itemID}"
          raise
        end
      end
    }

    # Finish off the last batch.
    batch[:items].empty? or $batchQueue << batch
  rescue Exception => e
    puts "Exception in indexAllItems: #{e} #{e.backtrace}"
  ensure
    $batchQueue << nil   # marker for end-of-queue
  end
end

###################################################################################################
def updateIssueAndSection(data)
  iss, sec = data[:dbIssue], data[:dbSection]
  (iss && sec) or return

  found = Issue.first(unit_id: iss.unit_id, volume: iss.volume, issue: iss.issue)
  if found
    issueChanged = false
    if found.pub_date != iss.pub_date
      #puts "issue #{iss.unit_id} #{iss.volume}/#{iss.issue} pub date changed from #{found.pub_date.inspect} to #{iss.pub_date.inspect}."
      found.pub_date = iss.pub_date
      issueChanged = true
    end
    if found.attrs != iss.attrs
      #puts "issue #{iss.unit_id} #{iss.volume}/#{iss.issue} attrs changed from #{found.attrs.inspect} to #{iss.attrs.inspect}."
      found.attrs = iss.attrs
      issueChanged = true
    end
    issueChanged and found.save
    iss = found
  else
    iss.save
  end

  found = Section.first(issue_id: iss.id, name: sec.name)
  if found
    secChanged = false
    if found.ordering != sec.ordering
      found.ordering = sec.ordering
      secChanged = true
    end
    begin
      secChanged and found.save
    rescue Exception => e
      if e.to_s =~ /Duplicate entry/
        puts "Warning: couldn't update section order due to ordering constraint. Ignoring."
      else
        raise
      end
    end
    sec = found
  else
    sec.issue_id = iss.id
    begin
      sec.save
    rescue Exception => e
      if e.to_s =~ /Duplicate entry/
        puts "Warning: couldn't update section order due to ordering constraint. Ignoring."
        sec.ordering = nil
        sec.save
      else
        raise
      end
    end
  end
  data[:dbItem][:section] = sec.id
end

###################################################################################################
def scrubSectionsAndIssues()
  # Remove orphaned sections and issues (can happen when items change)
  $dbMutex.synchronize {
    DB.run("delete from sections where id not in (select distinct section from items where section is not null)")
    DB.run("delete from issues where id not in (select distinct issue_id from sections where issue_id is not null)")
  }
end

###################################################################################################
def updateDbItem(data)
  itemID = data[:dbItem][:id]

  # Delete any existing data related to this item
  ItemAuthor.where(item_id: itemID).delete
  UnitItem.where(item_id: itemID).delete
  ItemCount.where(item_id: itemID).delete

  # Insert (or update) the issue and section
  updateIssueAndSection(data)

  # Now insert the item and its authors
  Item.where(id: itemID).delete
  data[:dbItem].save()
  data[:dbAuthors].each { |dbAuth|
    dbAuth.save()
  }

  # Copy item counts from the old stats database
  STATS_DB.fetch("SELECT * FROM itemCounts WHERE itemId = ?", itemID.sub(/^qt/, "")) { |row|
    ItemCount.insert(item_id: itemID, month: row[:month], hits: row[:hits], downloads: row[:downloads])
  }

  # Link the item to its units
  done = Set.new
  aorder = 10000
  data[:units].each_with_index { |unitID, order|
    if !done.include?(unitID)
      UnitItem.create(
        :unit_id => unitID,
        :item_id => itemID,
        :ordering_of_units => order,
        :is_direct => true
      )
      done << unitID

      $unitAncestors[unitID].each { |ancestor|
        if !done.include?(ancestor)
          UnitItem.create(
            :unit_id => ancestor,
            :item_id => itemID,
            :ordering_of_units => aorder,  # maybe should this column allow null?
            :is_direct => false
          )
          aorder += 1
          done << ancestor
        end
      }
    end
  }
end

###################################################################################################
def submitBatch(batch)
  # Try for 10 minutes max. CloudSearch seems to go awol fairly often.
  startTime = Time.now
  begin
    $csClient.upload_documents(documents: batch[:idxData], content_type: "application/json")
  rescue Exception => res
    if res.inspect =~ /Http(408|5\d\d)Error|ReadTimeout|ServiceUnavailable/ && (Time.now - startTime < 10*60)
      puts "Will retry in 30 sec, response was: #{res}"
      sleep 30; puts "Retrying."; retry
    end
    puts "Unable to retry: #{res.inspect}, elapsed=#{Time.now - startTime}"
    raise
  end
end

###################################################################################################
def processBatch(batch)
  puts "Processing batch: nItems=#{batch[:items].size}, size=#{batch[:idxDataSize]}."

  # Finish the data buffer, and send to AWS
  if !$noCloudSearchMode
    batch[:idxData] << "]"
    submitBatch(batch)
  end

  # Now that we've successfully added the documents to AWS CloudSearch, insert records into
  # our database. For efficiency, do all the records in a single transaction.
  $dbMutex.synchronize {
    DB.transaction do
      batch[:items].each { |data| updateDbItem(data) }
    end
  }

  # Periodically scrub out orphaned sections and issues
  $scrubCount += 1
  if $scrubCount > 5
    scrubSectionsAndIssues()
    $scrubCount = 0
  end

  # Update status
  $nProcessed += batch[:items].size
  puts "#{$nProcessed} processed + #{$nUnchanged} unchanged + #{$nSkipped} " +
       "skipped = #{$nProcessed + $nUnchanged + $nSkipped} of #{$nTotal} total"
end

###################################################################################################
# Process every batch in our queue
def processAllBatches
  Thread.current[:name] = "batch thread"  # label all stdout from this thread
  loop do
    # Grab a batch from the input queue
    batch = $batchQueue.pop
    batch or break

    # And process it
    processBatch(batch)
  end
end

###################################################################################################
# Delete extraneous units from prior conversions
def deleteExtraUnits(allIds)
  dbUnits = Set.new(Unit.map { |unit| unit.id })
  (dbUnits - allIds).each { |id|
    puts "Deleting extra unit: #{id}"
    DB.transaction do
      items = UnitItem.where(unit_id: id).map { |link| link.item_id }
      UnitItem.where(unit_id: id).delete
      items.each { |itemID|
        if UnitItem.where(item_id: itemID).empty?
          ItemAuthor.where(item_id: itemID).delete
          Item[itemID].delete
        end
      }

      Issue.where(unit_id: id).each { |issue|
        Section.where(issue_id: issue.id).delete
      }
      Issue.where(unit_id: id).delete

      Widget.where(unit_id: id).delete

      UnitHier.where(ancestor_unit: id).delete
      UnitHier.where(unit_id: id).delete

      Unit[id].delete
    end
  }
end

###################################################################################################
# Main driver for unit conversion.
def convertAllUnits(units)
  # Let the user know what we're doing
  puts "Converting #{units=="ALL" ? "all" : "selected"} units."
  startTime = Time.now

  # Load allStruct and traverse it. This will create Unit and Unit_hier records for all units,
  # and delete any extraneous old ones.
  allStructPath = "/apps/eschol/erep/xtf/style/textIndexer/mapping/allStruct-eschol5.xml"
  open(allStructPath, "r") { |io|
    convertUnits(fileToXML(allStructPath).root, {}, {}, Set.new, units)
  }
end

###################################################################################################
def getShortArk(arkStr)
  arkStr =~ %r{^ark:/?13030/(qt\w{8})$} and return $1
  arkStr =~ /^(qt\w{8})$/ and return arkStr
  arkStr =~ /^\w{8}$/ and return "qt#{arkStr}"
  raise("Can't parse ark from #{arkStr.inspect}")
end

###################################################################################################
def cacheAllUnits()
  # Build a list of all valid units
  $allUnits = Unit.map { |unit| [unit.id, unit] }.to_h

  # Build a cache of unit ancestors
  $unitAncestors = Hash.new { |h,k| h[k] = [] }
  UnitHier.each { |hier| $unitAncestors[hier.unit_id] << hier.ancestor_unit }
end

###################################################################################################
# Main driver for item conversion
def convertAllItems(arks)
  # Let the user know what we're doing
  puts "Converting #{arks=="ALL" ? "all" : "selected"} items."

  cacheAllUnits()

  # Fire up threads for doing the work in parallel
  Thread.abort_on_exception = true
  indexThread = Thread.new { indexAllItems }
  batchThread = Thread.new { processAllBatches }

  # Count how many total there are, for status updates
  $nTotal = QUEUE_DB.fetch("SELECT count(*) as total FROM indexStates WHERE indexName='erep'").first[:total]

  # Grab the timestamps of all items, for speed
  $allItemTimes = (arks=="ALL" ? Item : Item.where(id: arks.to_a)).to_hash(:id, :last_indexed)

  # Convert all the items that are indexable
  query = QUEUE_DB[:indexStates].where(indexName: 'erep').select(:itemId, :time).order(:itemId)
  $nTotal = query.count
  if $skipTo
    puts "Skipping all up to #{$skipTo}..."
    query = query.where{ itemId >= "ark:13030/#{$skipTo}" }
    $nSkipped = $nTotal - query.count
  end
  query.all.each do |row|   # all so we don't keep db locked
    shortArk = getShortArk(row[:itemId])
    next if arks != 'ALL' && !arks.include?(shortArk)
    erepTime = Time.at(row[:time].to_i).to_time
    itemTime = $allItemTimes[shortArk]
    if itemTime.nil? || itemTime < erepTime || $rescanMode
      $indexQueue << [shortArk, erepTime]
    else
      #puts "#{shortArk} is up to date, skipping."
      $nSkipped += 1
    end
  end

  $indexQueue << nil  # end-of-queue
  indexThread.join
  batchThread.join

  scrubSectionsAndIssues() # one final scrub
end

###################################################################################################
def flushInfoBatch(batch, force = false)
  if !batch[:dbUpdates].empty? && (force || batch[:idxDataSize] > MAX_BATCH_SIZE)
    puts "Submitting batch with #{batch[:dbUpdates].length} info records."
    batch[:idxData] << "]"
    submitBatch(batch)

    # Now that the data is in AWS, update the DB records.
    DB.transaction {
      batch[:dbUpdates].each { |func| func.call }
    }

    # And clear out the batch for the next round
    batch[:dbUpdates] = []
    batch[:idxData] = "["
    batch[:idxDataSize] = 0
  end
end

###################################################################################################
def indexUnit(row, batch)

  # Create JSON for the full text index
  unitID = row[:id]
  oldDigest = row[:index_digest]
  idxItem = {
    type:          "add",   # in CloudSearch land this means "add or update"
    id:            "unit:#{unitID}",
    fields: {
      text:          row[:name],
      is_info:       1
    }
  }

  # Determine campus(es), department(s), and journal(s) by tracing the unit connnections.
  addIdxUnits(idxItem, [unitID])

  idxData = JSON.generate(idxItem)
  idxDigest = Digest::MD5.base64digest(idxData)
  if oldDigest && oldDigest == idxDigest
    #puts "Unchanged: unit #{unitID}"
  else
    puts "#{oldDigest ? "Changed" : "New"}: unit #{unitID}"

    # Now add this item to the batch
    batch[:dbUpdates].empty? or batch[:idxData] << ",\n"  # Separator between records
    batch[:idxData] << idxData
    batch[:idxDataSize] += idxData.bytesize
    batch[:dbUpdates] << lambda {
      if oldDigest
        InfoIndex.where(unit_id: unitID, page_slug: nil, freshdesk_id: nil).update(index_digest: idxDigest)
      else
        InfoIndex.new { |info|
          info[:unit_id] = unitID
          info[:page_slug] = nil
          info[:freshdesk_id] = nil
          info[:index_digest] = idxDigest
        }.save
      end
    }
  end
end

###################################################################################################
def indexPage(row, batch)

  # Create JSON for the full text index
  unitID = row[:unit_id]
  slug = row[:slug]
  oldDigest = row[:index_digest]
  attrs = JSON.parse(row[:attrs])
  text = "#{$allUnits[unitID][:name]}\n#{row[:name]}\n#{row[:title]}\n"
  htmlText = attrs["html"]
  if htmlText
    buf = []
    traverseText(stringToXML(htmlText), buf)
    text += translateEntities(buf.join("\n"))
  end

  idxItem = {
    type:          "add",   # in CloudSearch land this means "add or update"
    id:            "page:#{unitID}:#{slug.gsub(%r{[^-a-zA-Z0-9\_\/\#\:\.\;\&\=\?\@\$\+\!\*'\(\)\,\%]}, '_')}",
    fields: {
      text:        text,
      is_info:     1
    }
  }

  # Determine campus(es), department(s), and journal(s) by tracing the unit connnections.
  addIdxUnits(idxItem, [unitID])

  idxData = JSON.generate(idxItem)
  idxDigest = Digest::MD5.base64digest(idxData)
  if oldDigest && oldDigest == idxDigest
    #puts "Unchanged: page #{unitID}:#{slug}"
  else
    puts "#{row[:index_digest] ? "Changed" : "New"}: page #{unitID}:#{slug}"

    # Now add this item to the batch
    batch[:dbUpdates].empty? or batch[:idxData] << ",\n"  # Separator between records
    batch[:idxData] << idxData
    batch[:idxDataSize] += idxData.bytesize
    batch[:dbUpdates] << lambda {
      if oldDigest
        InfoIndex.where(unit_id: unitID, page_slug: slug, freshdesk_id: nil).update(index_digest: idxDigest)
      else
        InfoIndex.new { |info|
          info[:unit_id] = unitID
          info[:page_slug] = slug
          info[:freshdesk_id] = nil
          info[:index_digest] = idxDigest
        }.save
      end
    }
  end
end

###################################################################################################
def deleteIndexUnit(unitID, batch)
  puts "Deleted: unit #{unitID}"
  idxItem = {
    type:          "delete",
    id:            "unit:#{unitID}"
  }
  idxData = JSON.generate(idxItem)
  batch[:dbUpdates].empty? or batch[:idxData] << ",\n"  # Separator between records
  batch[:idxData] << idxData
  batch[:idxDataSize] += idxData.bytesize
  batch[:dbUpdates] << lambda {
    InfoIndex.where(unit_id: unitID, page_slug: nil, freshdesk_id: nil).delete
  }
end

###################################################################################################
def deleteIndexPage(unitID, slug, batch)
  puts "Deleted: page #{unitID}:#{slug}"
  idxItem = {
    type:          "delete",
    id:            "page:#{unitID}:#{slug}"
  }
  idxData = JSON.generate(idxItem)
  batch[:dbUpdates].empty? or batch[:idxData] << ",\n"  # Separator between records
  batch[:idxData] << idxData
  batch[:idxDataSize] += idxData.bytesize
  batch[:dbUpdates] << lambda {
    InfoIndex.where(unit_id: unitID, page_slug: slug, freshdesk_id: nil).delete
  }
end

###################################################################################################
# Update the CloudSearch index for all info pages
def indexInfo()
  # Let the user know what we're doing
  puts "Checking and indexing info pages."

  # Build a list of all valid units
  cacheAllUnits()

  # First, the units that are new or changed
  batch = { dbUpdates: [], idxData: "[", idxDataSize: 0 }
  Unit.left_join(:info_index, unit_id: :id, page_slug: nil, freshdesk_id: nil).
       select(Sequel[:units][:id], :name, :page_slug, :freshdesk_id, :index_digest).each { |row|
    indexUnit(row, batch)
  }

  # Then the pages that are new or changed
  Page.left_join(:info_index, unit_id: :unit_id, page_slug: :slug).
       select(Sequel[:pages][:unit_id], :name, :title, :slug, :attrs, :index_digest).each { |row|
    indexPage(row, batch)
  }

  # Delete excess units and pages
  DB.fetch("SELECT unit_id FROM info_index WHERE page_slug IS NULL AND freshdesk_id IS NULL " +
           "AND NOT EXISTS (SELECT * FROM units WHERE info_index.unit_id = units.id)").each { |row|
    deleteIndexUnit(row[:unit_id], batch)
  }
  DB.fetch("SELECT unit_id, page_slug FROM info_index WHERE page_slug IS NOT NULL " +
           "AND NOT EXISTS (SELECT * FROM pages WHERE info_index.unit_id = pages.unit_id " +
           "                                      AND info_index.page_slug = pages.slug)").each { |row|
    deleteIndexPage(row[:unit_id], row[:page_slug], batch)
  }

  # Flush the last batch
  flushInfoBatch(batch, true)
end

###################################################################################################
# Main driver for PDF display version generation
def convertPDF(itemID)
  item = Item[itemID]
  attrs = JSON.parse(item.attrs)

  # Generate the splash instructions, for cache checking
  instrucs = splashInstrucs(itemID, item, attrs)
  instrucDigest = Digest::MD5.base64digest(instrucs.to_json)

  # See if current splash page is adequate
  origFile = arkToFile(itemID, "content/base.pdf")
  if !File.exist?(origFile)
    puts "Missing content file; skipping."
    return
  end
  origSize = File.size(origFile)

  dbPdf = DisplayPDF[itemID]
  if !$forceMode && dbPdf && dbPdf.orig_size == origSize
    #puts "Unchanged."
    return
  end
  puts "Updating."

  # Linearize the original PDF
  linFile, linDiff, splashLinFile, splashLinDiff = nil, nil, nil, nil
  begin
    # First, linearize the original file. This will make the first page display quickly in our
    # pdf.js view on the item page.
    linFile = Tempfile.new(["linearized_#{itemID}_", ".pdf"], TEMP_DIR)
    system("/usr/bin/qpdf --linearize #{origFile} #{linFile.path}")
    code = $?.exitstatus
    code == 0 || code == 3 or raise("Error #{code} linearizing.")
    linSize = File.size(linFile.path)

    # Then generate a splash page, and linearize that as well.
    splashLinFile = Tempfile.new(["splashLin_#{itemID}_", ".pdf"], TEMP_DIR)
    splashLinSize = 0
    begin
      splashGen(itemID, instrucs, linFile, splashLinFile.path)
      splashLinSize = File.size(splashLinFile.path)
    rescue Exception => e
      if e.to_s =~ /Internal Server Error/
        puts "Warning: splash generator failed; falling back to plain."
      else
        raise
      end
    end

    $s3Bucket.object("#{$s3Config.prefix}/pdf_patches/linearized/#{itemID}").put(body: linFile)
    splashLinSize > 0 and $s3Bucket.object("#{$s3Config.prefix}/pdf_patches/splash/#{itemID}").put(body: splashLinFile)

    DisplayPDF.where(item_id: itemID).delete
    DisplayPDF.create(item_id: itemID,
      orig_size:          origSize,
      orig_timestamp:     File.mtime(origFile),
      linear_size:        linSize,
      splash_info_digest: splashLinSize > 0 ? instrucDigest : nil,
      splash_size:        splashLinSize
    )

    puts sprintf("Updated: lin=%d/%d = %.1f%%; splashLin=%d/%d = %.1f%%",
                 linSize, origSize, linSize*100.0/origSize,
                 splashLinSize, origSize, splashLinSize*100.0/origSize)
  ensure
    linFile and linFile.unlink
    linDiff and linDiff.unlink
    splashLinFile and splashLinFile.unlink
    splashLinDiff and splashLinDiff.unlink
  end
end

###################################################################################################
def splashFromQueue
  loop do
    # Grab an item from the input queue
    itemID = $splashQueue.pop
    itemID or break
    Thread.current[:name] = itemID  # label all stdout from this thread
    begin
      convertPDF(itemID)
    rescue Exception => e
      e.is_a?(Interrupt) || e.is_a?(SignalException) and raise
      puts "Exception: #{e} #{e.backtrace}"
    end
    Thread.current[:name] = nil
  end
end

###################################################################################################
# Main driver for PDF display version generation
def splashAllPDFs(arks)
  # Let the user know what we're doing
  puts "Splashing #{arks=="ALL" ? "all" : "selected"} PDFs."

  # Start a couple worker threads to do the splash conversions.
  nThreads = 2
  splashThreads = nThreads.times.map { Thread.new { splashFromQueue } }

  # Grab all the arks
  if arks == "ALL"
    Item.where(content_type: "application/pdf").order(:id).each { |item|
      $splashQueue << item.id
    }
  else
    arks.each { |item| $splashQueue << item }
  end

  nThreads.times { $splashQueue << nil } # mark end-of-queue
  splashThreads.each { |t| t.join }
end

###################################################################################################
# Update item and unit stats
def updateUnitStats
  puts "Updating unit stats."
  cacheAllUnits
  $allUnits.keys.sort.each_slice(10) { |slice|
    slice.each { |unitID|
      DB.transaction {
        UnitCount.where(unit_id: unitID).delete
        STATS_DB.fetch("SELECT * FROM unitCounts WHERE unitId = ? and direct = 0", unitID) { |row|
          UnitCount.insert(unit_id: unitID, month: row[:month],
                           hits: row[:hits], downloads: row[:downloads], items_posted: row[:nItemsPosted])
        }
      }
    }
  }
end

###################################################################################################
def flushDbQueue(queue)
  DB.transaction { queue.each { |func| func.call } }
  queue.clear
end

###################################################################################################
# Need to do queueing in a function to force the paramters to be captured. Doing a plain lambda
# inline gets references to variables which then change before lambdas get called.
def queueRedirect(queue, kind, from_path, to_path, descrip)
  queue << lambda {
    Redirect.create(kind: kind,
                    from_path: from_path,
                    to_path: to_path,
                    descrip: descrip)
  }
end

###################################################################################################
def convertOldStyleRedirects(kind, filename)
  # Skip if already done.
  !$forceMode && Redirect.where(kind: kind).count > 0 and return

  puts "Converting #{kind} redirects."
  Redirect.where(kind: kind).delete
  queue = []
  open("redirects/#{filename}").each_line do |line|
    line =~ %r{<from>(http://repositories.cdlib.org/)?([^<]+)</from>.*<to>([^<]+)</to>} or raise
    fp, tp = $2, $3
    fp.sub! "&amp;", "&"
    tp.sub! "&amp;", "&"
    tp.sub! %r{^/uc/search\?entity=(.*);volume=(.*);issue=(.*)}, '/uc/\1/\2/\3'
    queueRedirect(queue, kind, "/#{fp}", tp, nil)
    queue.length >= 1000 and flushDbQueue(queue)
  end
  flushDbQueue(queue)
end

###################################################################################################
def convertItemRedirects
  # Skip if already done.
  !$forceMode && Redirect.where(kind: 'item').count > 0 and return

  puts "Converting item redirects."
  Redirect.where(kind: 'item').delete
  fromArks = []
  comment = nil
  queue = []
  didArks = {}
  open("/apps/eschol/erep/xtf/style/dynaXML/docFormatter/pdf/objectRedirect.xsl").each_line do |line|
    if line =~ /test="matches/
      fromArks.empty? or raise("multiple whens with no value-of: #{line}")
      fromArks = line.scan /\b\d\w{7}\b/
      fromArks.empty? and raise("no fromArks found: #{line}")
    elsif line =~ %r{<!--(.*)-->}
      comment = $1.strip
      comment.empty? and comment = nil
    elsif line =~ /xsl:value-of/
      fromArks.empty? and raise("value-of without when: #{line}")
      line.sub! "/980931r'", "/980931rf'"  # hack missing char in old redirect
      toArks = line.scan /\b\d\w{7}\b/
      toArks.length == 1 or raise("need exactly one to-ark: #{line}")
      toArk = toArks[0]
      fromArks.each { |fromArk|
        if didArks.include? fromArk
          toArk != didArks[fromArk] and puts "Duplicate from=#{fromArk} to=#{didArks[fromArk]} vs #{toArk}. Skipping."
          next
        end
        queueRedirect(queue, 'item', "/uc/item/#{fromArk}", "/uc/item/#{toArk}", comment)
        queue.length >= 1000 and flushDbQueue(queue)
        didArks[fromArk] = toArk
      }
      comment = nil
      fromArks.clear
    end
  end
  flushDbQueue(queue)
end

###################################################################################################
def convertUnitRedirects
  # Skip if already done.
  !$forceMode && Redirect.where(kind: 'unit').count > 0 and return
  puts "Converting unit redirects."
  Redirect.where(kind: 'unit').delete

  fromUnit = nil
  queue = []
  open("/apps/eschol/erep/xtf/style/erepCommon/unitRedirect.xsl").each_line do |line|
    if line =~ /entity='([a-z0-9_]+)'/
      fromUnit.nil? or raise("multiple whens with no value-of: #{line}")
      fromUnit = $1
    elsif line =~ /replace\(\$http\.URL,\s*'([a-z0-9_]+)',\s*'([^']+)'/
      fromUnit.nil? and raise("value-of without when: #{line}")
      fromUnit == $1 or raise("value-of doesn't match when: #{line}")
      fp = "/uc/#{fromUnit}"
      tp = "/uc/#{$2}"
      queueRedirect(queue, 'unit', fp, tp, nil)
      fromUnit = nil
    end
  end
  flushDbQueue(queue)
end

###################################################################################################
def fixURL(url)
  url.sub(%r{^(https?://)([^/]+)//}, '\1\2/')
end

###################################################################################################
def convertLogRedirects
  # Skip if already done.
  !$forceMode && Redirect.where(kind: 'log').count > 0 and return
  puts "Converting log redirects."
  Redirect.where(kind: 'log').delete

  open("redirects/random_redirects").each_line do |line|
    fromURL, toURL, code = line.split("|")

    # Fix double slashes
    fromURL = fixURL(fromURL)
    toURL = fixURL(toURL)

    # www.escholarship -> escholarship
    next if fromURL.sub("www.escholarship.org", "escholarship.org") == toURL
    next if fromURL.sub(".pdf", "") == toURL

    # Screwing around with query params on items
    next if fromURL.sub(%r{(/uc/item/.*)\?.*}, '$1') == toURL.sub(%r{(/uc/item/.*)\?.*}, '$1')

    # Item redirects
    if fromURL =~ %r{/uc/item/([^/]+)}
      itemID = $1
      itemRedir = Redirect.where(kind: "item", from_path: "/uc/item/#{itemID}").first
      if itemRedir
        puts "item redirect found: #{itemID} -> #{itemRedir.to_path}"
        next
      end
    end

    puts "#{fromURL} -> #{toURL}"
  end
end

###################################################################################################
def convertRedirects
  convertOldStyleRedirects('bepress', 'bp_redirects')
  convertOldStyleRedirects('doj', 'doj_redirects')
  convertItemRedirects
  convertUnitRedirects
  #convertLogRedirects
end

###################################################################################################
# Main action begins here

startTime = Time.now

# MH: Could not for the life of me get File.flock to actually do what it
#     claims, so falling back to file existence check.
lockFile = "/tmp/jschol_convert.lock"
File.exist?(lockFile) or FileUtils.touch(lockFile)
lock = File.new(lockFile)
begin
  if !lock.flock(File::LOCK_EX | File::LOCK_NB)
    puts "Another copy is already running."
    exit 1
  end

  case ARGV[0]
    when "--units"
      puts "Unit conversion is now really dangerous. If you really want to do this, use --units-real"
      exit 1
    when "--units-real"
      units = ARGV.select { |a| a =~ /^[^-]/ }
      convertAllUnits(units.empty? ? "ALL" : Set.new(units))
    when "--items"
      arks = ARGV.select { |a| a =~ /qt\w{8}/ }
      convertAllItems(arks.empty? ? "ALL" : Set.new(arks))
    when "--info"
      indexInfo()
    when "--splash"
      arks = ARGV.select { |a| a =~ /qt\w{8}/ }
      splashAllPDFs(arks.empty? ? "ALL" : Set.new(arks))
    when "--stats"
      updateUnitStats
    when "--redirects"
      convertRedirects
    else
      STDERR.puts "Usage: #{__FILE__} --units|--items"
      exit 1
  end

  puts "Elapsed: #{Time.now - startTime} sec."
  puts "Done."
ensure
  lock.flock(File::LOCK_UN)
end
