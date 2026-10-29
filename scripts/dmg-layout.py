#!/usr/bin/env python3
"""Write a self-contained Finder layout into the disk-image staging folder."""
import argparse
from pathlib import Path

from ds_store import DSStore


def configure(folder: Path):
    app = folder / 'Poieva Translate.app'
    applications = folder / 'Applications'
    if not app.is_dir() or not applications.is_symlink() or applications.readlink() != Path('/Applications'):
        raise ValueError('Expected the signed app and an /Applications shortcut in the staging folder.')

    # Finder reads these records from the volume root. No UI scripting, cached
    # paths, or background aliases tied to the build machine are required.
    window = {
        'WindowBounds': '{{180, 160}, {660, 420}}',
        'ShowToolbar': False,
        'ShowSidebar': False,
        'ContainerShowSidebar': False,
        'ShowStatusBar': False,
        'ShowPathbar': False,
        'ShowTabView': False,
        'PreviewPaneVisibility': False,
    }
    icons = {
        'viewOptionsVersion': 1,
        'backgroundType': 1,
        'backgroundColorRed': 1.0,
        'backgroundColorGreen': 1.0,
        'backgroundColorBlue': 1.0,
        'iconSize': 128.0,
        'textSize': 15.0,
        'labelOnBottom': True,
        'arrangeBy': 'none',
        'gridOffsetX': 0.0,
        'gridOffsetY': 0.0,
        'gridSpacing': 100.0,
        'scrollPositionX': 0.0,
        'scrollPositionY': 0.0,
        'showIconPreview': False,
        'showItemInfo': False,
    }
    with DSStore.open(str(folder / '.DS_Store'), 'w+') as store:
        store['.']['bwsp'] = window
        store['.']['icvp'] = icons
        store['.']['vSrn'] = ('long', 1)
        store['.']['vstl'] = ('type', b'icnv')
        store[app.name]['Iloc'] = (170, 205)
        store[applications.name]['Iloc'] = (490, 205)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    configure(parser.parse_args().folder)
