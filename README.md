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

The script `use FindBin` and `use lib` to find the modules.

## Usage

| Option | Description |
| :- | :- |
| `--dir=directory` | Use the specified as Notable data directory. Defaults to `.`, the current directory. |
| `--verbose` | Be verbose, that is, more output. |
| `--debug` | Even more output. Useful for debugging only. |
| `--test` | Don't write anything to any files. |
| `--maxnotes=n` | Process a maximum of *n* notes in one run. Useful for testing that the result is what you expected before processing an entire BibTeX file or all notes. |

### Import a BibTeX file to Notable

For each entry in the BibTeX file, the script tries to find the corresponding note in the Notable database and stores the entire BibTeX entry in the YAML frontmatter. Take, for example, the following BibTeX entry (actually [BibLaTeX](https://www.ctan.org/pkg/biblatex), but when importing field names doesn't matter):

```bibtex
@article{Upper1974,
  author       = {Upper, Dennis},
  title        = {The unsuccessful self-treatment of a case of ``writer's block''},
  journaltitle = {Journal of Applied Behavior Analysis},
  year         = 1974,
  volume       = 7,
  number       = 3,
  pages        = 497,
  doi          = {10.1901/jaba.1974.7-497a},
}
```

That entry is stored as following YAML frontmatter:

```yaml
---
created: 2022-02-23T12:22:04.000Z
modified: 2022-02-23T12:24:43.000Z
title: Upper (1974) The unsuccessful self-treatment of a case of writer's block
bibtex:
  _key: Upper1974
  _type: article
  author: Upper, Dennis
  doi: 10.1901/jaba.1974.7-497a
  journaltitle: Journal of Applied Behavior Analysis
  number: '3'
  pages: '497'
  title: The unsuccessful self-treatment of a case of ``writer's block''
  volume: '7'
  year: '1974'
---
```

The script first tries to find a corresponding note with the same BibTeX key. Second, it tries to search note titles for a matching title (expecting notes to be named with "Author (year) Title", like "Upper (1974) The unsuccessful self-treatment of a case of writer's block"). If none of that works, the script add a new note to the Notable directory.

To import a BibTeX file to Notable:

```sh
notable-bibtex.pl import --bibliography=bibliography.bib
```

| Option | Description |
| :- | :- |
| `--bibliography=file.bib` | Import `file.bib`. Can be specified multiple times to import several bibliographies. |
| `--test` | Don't write or update any Notable notes. |

## Export