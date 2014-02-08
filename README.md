gem2arch is a tool that simplifies creation and maintenance of RubyGem packages for [Arch Linux](https://www.archlinux.org/). [RubyGems](https://rubygems.org/) is an advanced package manager that already contains all of the required information. gem2arch uses that information to generate or update PKGBUILD files.

Program arguments
-----------------
    gem2arch [options] [gemname[~version]]...

If one or more gem names are specified, the tool will generate PKGBUILD files for them. If any of the gem dependencies does not have a corresponding Arch package, then the tool will generate them recursively. If the package is present in an official repository or the AUR, but the version is out-of-date, then the tool will print a warning that reminds users to keep packages up-to-date.

If no gem names are specified, then the tool works in '_version bump_' mode. It will read all _ruby-\*/PKGBUILD_ files, parse them, and update the version and dependencies if needed. Unlike '_create_' mode, it tries to minimize the amount of changes to existing PKGBUILD files.

Program options
---------------
    --[no-]git - Commit PKGBUILD changes to Git repository. One change per package bump.
    --[no-]aur - Upload modified package to the AUR.
    --[no-]install - Install generated Arch packages

Example:

    $ gem2arch rails iobuffer~1.1
will generate a PKGBUILD for ruby and iobuffer-1.1.x that will point to the latest version available in the RubyGems index. If any of the dependencies is absent, then the corresponding package will be created as well.

License
-------
GPL3
