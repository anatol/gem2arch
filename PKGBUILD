# gem2arch created by: Anatol Pomozov https://github.com/anatol
# PKGBUILD added by: Johannes Ernst https://github.com/jernst

pkgname=$(basename $(pwd))
pkgver=0.11
pkgrel=1
pkgdesc='Simplifies creation and maintenance of RubyGem packages for Arch Linux'
arch=('any')
url='https://github.com/jernst/gem2arch'
license=('GPLv3')
depends=('ruby' 'ruby-erubis')

package() {
  mkdir -p ${pkgdir}/usr/bin
  install -m755 ${startdir}/gem2arch.rb ${pkgdir}/usr/bin/gem2arch
}

