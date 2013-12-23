gem2arch is a tool that simplifies creation and maintainence of rubygem packages for [Linux Arch](https://www.archlinux.org/). [Rubygems](http://rubygems.org/) is an advanced package manager that already contains al required information, gem2arch uses that information to generate or update PKGBUILD files.

Program arguments
---
    gem2arch [options] [gemname[~version]]...

If one or more gem names are specified the tool will generate PKGBUILD files. If any of the gem depenencies does not have corresponding Arch packages then the tool will generate them recursively. If the package is present in official repository or AUR but version is out of date the tool will print a warning helping users to keep package up-to-date.

If no gem names are specified then tool works in '_version bump_' mode. It will read all _ruby-\*/PKGBUILD_ files parse them and update version and dependencies if needed. Unlike '_create_' mode it tries to minimize amount of changes to existing PKGBUILD files.

Program options
---
    --[no-]git - Commit codifications to git repository. One change per apckage bump.
    --[no-]aur - Upload modified package to AUR.
    --[no-]install - Install generated Arch packages

Example:

    $ gem2arch rails iobuffer~1.1
will generate PKGBUILD for ruby and iobuffer-1.1.x that will point to the latest version available in rubygems index. If any of the dependencies is absent then corresponding package will be created as well.


License
----
GPL3
