# dmgbuild settings: https://dmgbuild.readthedocs.io
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"            # LZFSE: smaller, macOS 10.11+
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = None
icon = defines["icon"]     # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (170, 205),
    "Applications": (490, 205),
}
