# notable-bibtex

A script to convert between a BibTeX bibliography (`.bib` file) and a [Notable](https://notable.app) database.

## Install

The script depends on two unpublished Perl modules, [Text::BibLaTeX](https://github.com/bluebirch/text-biblatex) and [Notable](https://github.com/bluebirch/Notable). I have included them as submodules, so installing should be as simple as:

```sh
git clone https://github.com/bluebirch/notable-bibtex.git
cd notable-bibtex
git submodule init
git submodule update
```

The script `use FindBin` and `use lib` to find the installed modules.

## Usage

Global options:

`--dir=<dir>`
: Use `<dir>` as Notable data directory. Defaults to `.`, the current directory.

### Import

To import a BibTeX file to Notable:

```sh
notable-bibtex.pl import --bibliography=bibliography.bib
```

