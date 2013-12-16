#!/usr/bin/ruby

# A script that reads files 'ruby-*/PKGBUILD' and checks if it uses the latest version of gem
# if not - it updates version, pkgrel and dependencies

require 'json'
require 'ostruct'
require 'rubygems/name_tuple'
require 'rubygems/remote_fetcher'

# A number of gems is provided by standard 'ruby' package.
# There are several packages provided but only a few of them conflict with *.gem
CONFLICT_GEMS = %w(rake rdoc)

class PkgBuild
  attr_reader :name, :slot, :dependencies
  attr_accessor :version, :release

  def initialize(filename)
    @filename = filename
    @content = IO.read(@filename)

    @name = @content.match('_gemname=(\S+)')[1]
    @version = @content.match('pkgver=([\d\.]+)')[1]
    @release = @content.match('pkgrel=(\d+)')[1].to_i
    # dependencies contains only native (non-gem) packages
    @dependencies = @content.match('depends=\((.*)\)')[1].split.reject{|d| d.start_with?('ruby-')}
    @slot = @content.match('pkgname=ruby-\$_gemname-([\d\.]+)')[1] rescue nil
  end

  def to_s
    str = 'ruby-' + @name
    str = str + '-' + @slot if @slot
    return str
  end

  def save
    modified = false
    version_bump = false

    # we can change wither dependencies or version
    dep = @dependencies.join(' ')

    m = @content.match('depends=\((.*)\)')[1]
    if m != dep
      modified = true
      @release += 1
      @content.gsub!(/depends=\((.*)\)/, "depends=\(#{dep}\)")
    end

    m = @content.match('pkgver=([\d\.]+)')[1]
    if m != @version
      modified = true
      version_bump = true
      @release = 1
      @content.gsub!(/pkgver=([\d\.]+)/, "pkgver=#{@version}")
    end

    @content.gsub!(/pkgrel=\d+/, "pkgrel=#{@release}")

    IO.write(@filename, @content)

    if version_bump
      `cd #{File.dirname(@filename)} && updpkgsums 2> /dev/null`
      abort("Cannot run updpkgsums for modifications in #{@filename}") unless $?.success?
    end

    return modified
  end

  def upload
    dir = File.dirname(@filename)
    `cd #{dir} && rm -f *.src.tar.gz && makepkg -f -i && makepkg -S && burp ruby-#{@name}-#{@version}-#{@release}.src.tar.gz`
    return $?.success?
  end
end

def pkg_to_spec(pkg)
  req = nil
  if pkg.slot
    req = Gem::Requirement.new('~>' + pkg.slot + '.0')
  end

  dep = Gem::Dependency.new(pkg.name, req)
  found,_ = Gem::SpecFetcher.fetcher.spec_for_dependency(dep)
  if found.empty?
    puts "Could not find gem releases for package #{arch_name}"
    return nil
  end

  spec,_ = found.sort_by{|(s,_)| s.version }.last
  return spec
end

# converts ruby dependency into arch name
# the problem is when dependency uses '=' or '~>' restriction that does not match the last version of the package
# we need to find the least restricted versioned arch package name
def dependency_suffix(dep)
  dep.to_s # this is a workaround for "undefined method `none?'". I can't explain it (ruby GC issue?).
  return nil if dep.latest_version?

  # TODO: @index is sorted - we can use bsearch here
  all_versions = @index.select{|t| t.name == dep.name}

  # now we need to find the best (the last) version that matches provided dependency
  required_ind = all_versions.rindex{|s| dep.requirement.satisfied_by?(s.version)}
  required_version = all_versions[required_ind]
  next_version = all_versions[required_ind+1]

  abort("Cannot resolve package dependency: #{dep}") unless required_version
  # if required version is already the last version then we don't need a versioned dependency
  return nil unless next_version

  suffix = ''
  v1 = required_version.version.to_s.split('.')
  v2 = next_version.version.to_s.split('.')
  v1.zip(v2).each do |p1,p2|
    abort("Cannot generate arch name for dependency #{dep}") unless p1
    if p1 == p2
      suffix = suffix + p1 + '.'
    else
      suffix = suffix + p1
      break
    end
  end

  return suffix
end

def load_gem_index
  url = Gem.default_sources[0]
  source = Gem::Source.new(url)
  source.load_specs(:released).select{|s| s.match_platform?}
end

@version_cache = {} # String->OpenStruct
def find_arch_version(package, gem_name, suffix)
  return @version_cache[package] if @version_cache.include?(package)

  pkg = nil
  # First check extra/community
  pacinfo = `pacman -Si #{package} 2>/dev/null`
  if $?.success? then
    pkg = OpenStruct.new
    pkg.aur = false
    pkg.version = /Version\s*:(.*)-\d+/.match(pacinfo)[1].strip
    repo = /Repository\s*:(.*)/.match(pacinfo)[1].strip
    arch = /Architecture\s*:(.*)/.match(pacinfo)[1].strip
    pkg.url = "https://www.archlinux.org/packages/#{repo}/#{arch}/#{package}/"
  end

  unless pkg
    aur_request = "https://aur.archlinux.org/rpc.php?type=info&arg=#{package}"
    resp = Net::HTTP.get_response(URI.parse(aur_request))
    result = JSON.parse(resp.body)
    if result['resultcount'] > 0
      pkg = OpenStruct.new
      pkg.aur = true
      pkg.url = "https://aur.archlinux.org/packages/#{package}/"
      pkg.version = /(.*)-\d+/.match(result['results']['Version'])[1]
    end
  end

  @version_cache[package] = pkg

  if pkg
    if suffix
      req = Gem::Requirement.new('~>' + suffix + '.0')
    else
      req = Gem::Requirement.default
    end
    latest = @index.select{|i| i.name == gem_name and req.satisfied_by?(i.version)}.last
    if latest.version.to_s != pkg.version
      puts "Package #{package} is out-of-date (repo=#{pkg.version} gem=#{latest.version.to_s}). Please visit #{pkg.url} and mark it so."
    end
  else
    puts "Package #{package} does not exist. Please create one."
  end

  return pkg
end


@index = load_gem_index()
`git stash save 'Save before gembump.rb'`
version_cache = {} # arch_name -> Gem::Version
out_of_date = []

for f in Dir['ruby-*/PKGBUILD'] do
  correct_deps = true

  pkg = PkgBuild.new(f)
  spec = pkg_to_spec(pkg)
  next unless spec

  pkg.version = spec.version.to_s
  new_deps = spec.runtime_dependencies.reject{|d| CONFLICT_GEMS.include?(d.name) }
  for d in new_deps
    suffix = dependency_suffix(d)
    arch_name = 'ruby-' + d.name
    arch_name += '-' + suffix if suffix
    pkg.dependencies << arch_name

    arch_pkg = find_arch_version(arch_name, d.name, suffix)
    unless arch_pkg
      # no such package
      correct_deps = false
      break
    end

    # make sure we match spec requirement
    unless d.requirement.satisfied_by?(Gem::Version.new(arch_pkg.version))
      correct_deps = false
      puts "#{pkg.to_s}=>#{arch_name} does not satisfy gem dependency restrictions"
    end
  end

  next unless correct_deps

  modified = pkg.save
  if modified
    uploaded = pkg.upload
    if uploaded
      `git add #{f} && git commit -m '#{pkg}: bump'`
    else
      puts "Cannot upload changes for package #{pkg}"
    end
  end
end
