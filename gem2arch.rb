#!/usr/bin/ruby

require 'date'
require 'digest/sha1'
require 'erubis'
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'ostruct'
require 'rubygems'
require 'rubygems/package'

#TODO: generate correct native depepdencies (spec.requirements)
#TODO: build packages recursively (i.e. for depepdencies as well)
#TODO: check spec.required_ruby_version matches current version
#TODO: check dependency version matching
#TODO: remove /ext/ folder

PKGBUILD = %{# Generated by gem2arch (https://github.com/anatol/gem2arch)
<% for m in maintainers %>
# Maintainer: <%= m %>
<% end %>
<% for c in contributors %>
# Contributor: <%= c %>
<% end %>

_gemname=<%= gem_name %>
pkgname=ruby-$_gemname<%= version_suffix %>
pkgver=<%= gem_ver %>
pkgrel=1
pkgdesc='<%= description %>'
arch=(<%= arch %>)
url='<%= website %>'
license=(<%= license %>)
depends=(<%= depends %>)
options=(!emptydirs)
source=(https://rubygems.org/downloads/$_gemname-$pkgver.gem)
noextract=($_gemname-$pkgver.gem)
sha1sums=('<%= sha1sum %>')

package() {
  local _gemdir="$(ruby -e'puts Gem.default_dir')"
  gem install --ignore-dependencies --no-user-install -i "$pkgdir/$_gemdir" -n "$pkgdir/usr/bin" $_gemname-$pkgver.gem
  rm "$pkgdir/$_gemdir/cache/$_gemname-$pkgver.gem"
<% for license in license_files %>
  install -D -m644 "$pkgdir/$_gemdir/gems/$_gemname-$pkgver/<%= license %>" "$pkgdir/usr/share/licenses/$pkgname/<%= license %>"
<% end %>
}
}

# A number of gems is provided by standard 'ruby' package.
# There are several packages provided but only a few of them conflict with *.gem
CONFLICT_GEMS = %w(rake rdoc)

def parse_args(args)
  options = OpenStruct.new
  options.install = true

  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: gem2arch [options] gem_name [package_suffix]\n
  If package_suffix present then arch package will be called ruby-$gem_name-$package_suffix and gem version will be ~>$package_suffix.0"

    opts.on('-i', '--[no-]install', 'Install generated arch packages') do |i|
      options.install = i
    end
  end

  opt_parser.parse!(args)
  if args.size < 1 or args.size > 2
    puts opt_parser.help
    exit 1
  end
  options.name = args[0]
  options.version = args[1]

  options
end

def shell_escape_string(str)
  str.gsub("'", "'\\\\''")
end

def find_package_version(package)
  pkg = OpenStruct.new

  # First check extra/community
  pacinfo = `pacman -Si #{package} 2>/dev/null`
  if $?.success? then
    pkg.aur = false
    pkg.version = /Version\s*:(.*)-\d+/.match(pacinfo)[1].strip
    repo = /Repository\s*:(.*)/.match(pacinfo)[1].strip
    arch = /Architecture\s*:(.*)/.match(pacinfo)[1].strip
    pkg.url = "https://www.archlinux.org/packages/#{repo}/#{arch}/#{package}/"
    return pkg
  end

  aur_request = "https://aur.archlinux.org/rpc.php?type=info&arg=#{package}"
  resp = Net::HTTP.get_response(URI.parse(aur_request))
  result = JSON.parse(resp.body)
  if result['resultcount'] > 0 then
    pkg.aur = true
    pkg.url = "https://aur.archlinux.org/packages/#{package}/"
    pkg.version = /(.*)-\d+/.match(result['results']['Version'])[1]
    return pkg
  end

  return nil
end

def download(gem_name, suffix = nil)
  req = suffix ? Gem::Requirement.new('~>' + suffix + '.0') : nil
  dependency = Gem::Dependency.new(gem_name, req)
  found, _ = Gem::SpecFetcher.fetcher.spec_for_dependency(dependency)

  if found.empty? then
    $stderr.puts "Could not find #{gem_name} in any repository"
    exit 1
  end

  spec, source = found.sort_by{ |(s,_)| s.version }.last
  path = Gem::RemoteFetcher.fetcher.download(spec, source.uri.to_s)

  return path
end

def read_pkgbuild_tags(content, tag)
  content.scan(/^\s*\#\s*#{tag}\s*:(.*)$/).flatten.map{|s| s.strip}.reject{|s| s.empty?}
end

def read_pkgbuild(file)
  pkg = OpenStruct.new
  pkg.maintainers = []
  pkg.contributors = []

  return pkg unless File.exists?(file)

  content = IO.read(file)
  pkg.maintainers = read_pkgbuild_tags(content, 'Maintainer')
  pkg.contributors = read_pkgbuild_tags(content, 'Contributor')

  # Many ruby gems do not have license field initialized. Read one from exising PKGBUILD so we can use later if upstream did not provide license.
  pkg.license = content.match('license\s*=(.*)')[1].scan(/[a-zA-Z\d\-\.]*/).flatten.reject{|s| s.empty?}[0]

  # TODO: Read package dependencies. If it does not start from ruby- then assume it is a native dependency. Preserve it.

  return pkg
end

def current_username
  # Many users have git configured. Let's use it to find current user/email.
  name = `git config --get user.name`.strip
  return nil unless $?.success?

  email = `git config --get user.email`.strip
  return nil unless $?.success?

  return nil if name.empty? or email.empty?
  return "#{name} <#{email}>"
end

def find_license_files(spec)
  # find files called COPYING or LICENSE in the root directory
  license_files = spec.files.select do |f|
    next false if f.index('/')
    next true if f.downcase.index('license')
    next true if f.downcase.index('copying')
    next true if f.downcase.index('copyright')
    false
  end

  return license_files
end

def check_gem_dependencies(dependencies)
  for d in dependencies do
    pkg = find_package_version('ruby-' + d.name)
    unless pkg
      $stderr.puts "Cannot find package for gem dependency: #{d.name}"
      # TODO: generate package for dependency as well
      next
    end

    # Fetch version information for the gem
    dep = Gem::Dependency.new(d.name, nil)
    dep_found, _ = Gem::SpecFetcher.fetcher.spec_for_dependency(dep)
    dep_spec, _ = dep_found.sort_by{ |(s,_)| s.version }.last
    if dep_spec.version.to_s != pkg.version then
      $stderr.puts "Arch package for #{d.name} version '#{pkg.version}' differs from gem database version '#{dep_spec.version}'"
      $stderr.puts "     Visit project page #{pkg.url} and mark package as out-of-date"
      # TODO: generate package for dependency as well
    end

    unless d.requirement.satisfied_by?(Gem::Version.new(pkg.version))
      $stderr.puts "Package ruby-#{d.name} version does not satisfy gem dependency"
      # Hmm.. Does it mean the it requires older version of gem?
    end
  end
end

def gen_pkgbuild(gem_path, existing_pkgbuild, suffix)
  gem = Gem::Package.new(gem_path)
  spec = gem.spec

  arch = spec.extensions.empty? ? 'any' : 'i686 x86_64'
  sha1sum = Digest::SHA1.file(gem_path).hexdigest

  gem_dependencies = spec.runtime_dependencies.reject{|d| CONFLICT_GEMS.include?(d.name) }
  check_gem_dependencies(gem_dependencies)
  depends = %w(ruby)
  depends += gem_dependencies.map{|d| 'ruby-' + d.name}

  spec_licenses = spec.licenses
  if spec_licenses.empty? and existing_pkgbuild.license
    spec_licenses = [existing_pkgbuild.license]
  end
  licenses = spec_licenses.map{|l| l.index(' ') ? "'#{l}'" : l}

  maintainers = existing_pkgbuild.maintainers
  contributors = existing_pkgbuild.contributors
  if maintainers.empty?
    username = current_username()
    maintainers = username ? [username] : ['']
  end

  version_suffix = suffix ? '-' + suffix : ''
  params = {
    gem_name: spec.name,
    gem_ver: spec.version,
    version_suffix: version_suffix,
    website: spec.homepage,
    description: shell_escape_string(spec.summary),
    license: licenses.join(' '),
    arch: arch,
    sha1sum: sha1sum,
    depends: depends.join(' '),
    license_files: find_license_files(spec),
    maintainers: maintainers,
    contributors: contributors
  }

  return Erubis::Eruby.new(PKGBUILD).result(params)
end

if $0 == __FILE__
  options = parse_args(ARGV)

  gem_path = download(options.name, options.version)
  pkg_name = 'ruby-' + options.name
  pkg_name += '-' + options.version if options.version
  Dir.mkdir(pkg_name) unless File.exist?(pkg_name)
  puts "Generate PKGBUILD for #{pkg_name}"

  pkgbuild_file = File.join(pkg_name, 'PKGBUILD')
  existing_pkgbuild = read_pkgbuild(pkgbuild_file)
  IO.write(pkgbuild_file, gen_pkgbuild(gem_path, existing_pkgbuild, options.version))
  FileUtils.cp(gem_path, pkg_name)
end
