// Window input events as klio_win_poll_event reports them: the pointer, key,
// text, focus, resize and close events a window's backend translates its
// platform's events into, with keys numbered by the desktop's (AWT's) virtual
// key codes and locations, as Compose Desktop's Key numbers them.
//
// An event is a type and up to KLIO_EV_VALUES values:
//   KLIO_EV_CLOSE    none
//   KLIO_EV_RESIZE   [0] width, [1] height
//   KLIO_EV_POINTER  [0] kind (KLIO_PTR_*), [1] x, [2] y, [3] scroll x,
//                    [4] scroll y, [5] the button that changed (KLIO_BTN_*),
//                    [6] the buttons held (bit per KLIO_BTN_* - 1),
//                    [7] modifiers (KLIO_MOD_*)
//   KLIO_EV_KEY      [0] 1 pressed / 2 released, [1] key code, [2] location,
//                    [3] the key's character (0xFFFF when none), [7] modifiers
//   KLIO_EV_TEXT     [0] count n (at most 10), [1..n] typed code points
//   KLIO_EV_FOCUS    [0] 1 gained / 0 lost
//   KLIO_EV_MOVE     [0] x, [1] y: the window frame's top-left on the screen,
//                    in points from the main screen's top-left
//   KLIO_EV_PLACEMENT [0] KLIO_PLACEMENT_*, [1] 1 when minimized
//   KLIO_EV_MENU     [0] the id of the menu item chosen (klio_win_set_menu)
//   KLIO_EV_TRAY_ACTION  a tray icon's action (klio_tray_poll_event): a double
//                    click on Windows, a right click on macOS
//
// KLIO_EV_CLOSE is a request: the window stays open until it is closed.
#pragma once

#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <cstring>
#include <deque>
#include <string>
#include <thread>
#include <utility>
#include <vector>

enum {
    KLIO_EV_NONE = 0,
    KLIO_EV_CLOSE = 2,
    KLIO_EV_RESIZE = 5,
    KLIO_EV_POINTER = 10,
    KLIO_EV_KEY = 11,
    KLIO_EV_TEXT = 12,
    KLIO_EV_FOCUS = 13,
    KLIO_EV_MOVE = 14,
    KLIO_EV_PLACEMENT = 15,
    KLIO_EV_MENU = 16,
    // Scripted input only: choose the menu item at the path klioScriptText
    // holds at [0], as a click on it would. The backend's poll performs it.
    KLIO_EV_MENU_PATH = 17,
    KLIO_EV_TRAY_ACTION = 18,
};

// A window's menu bar as klio_win_set_menu takes it: one entry per line,
// depth first, its fields separated by tabs:
//   depth kind id enabled state mnemonic keycode mods text
// kind is m (a menu), i (an item), c (a checkbox item), r (a radio button
// item) or s (a separator); depth 0 is a menu on the bar; state is 1 for a
// checked or selected item; mnemonic is a character's code or 0; keycode
// and mods are the item's shortcut as an AWT key code and KLIO_MOD_* bits
// (0 when it has none).
struct KlioMenuEntry {
    int depth = 0;
    char kind = 'i';
    int id = 0;
    bool enabled = true;
    bool state = false;
    int mnemonic = 0;
    int keycode = 0;
    int mods = 0;
    std::string text;
};

inline std::vector<KlioMenuEntry> klioParseMenu(const char* spec, size_t len) {
    std::vector<KlioMenuEntry> out;
    if (!spec) return out;
    const std::string s(spec, len);
    size_t start = 0;
    while (start < s.size()) {
        size_t end = s.find('\n', start);
        if (end == std::string::npos) end = s.size();
        const std::string line = s.substr(start, end - start);
        start = end + 1;
        if (line.empty()) continue;
        std::vector<std::string> f;
        size_t p = 0;
        for (int i = 0; i < 8; i++) {
            const size_t t = line.find('\t', p);
            if (t == std::string::npos) break;
            f.push_back(line.substr(p, t - p));
            p = t + 1;
        }
        if (f.size() < 8) continue;
        KlioMenuEntry e;
        e.depth = std::atoi(f[0].c_str());
        e.kind = f[1].empty() ? 'i' : f[1][0];
        e.id = std::atoi(f[2].c_str());
        e.enabled = f[3] == "1";
        e.state = f[4] == "1";
        e.mnemonic = std::atoi(f[5].c_str());
        e.keycode = std::atoi(f[6].c_str());
        e.mods = std::atoi(f[7].c_str());
        e.text = line.substr(p);
        out.push_back(e);
    }
    return out;
}

// The index in `entries` of the item at a slash-separated path of titles
// ("File/Open"), or -1.
inline int klioMenuFindPath(const std::vector<KlioMenuEntry>& entries, const std::string& path) {
    std::vector<std::string> parts;
    size_t p = 0;
    while (true) {
        const size_t slash = path.find('/', p);
        parts.push_back(path.substr(p, slash == std::string::npos ? std::string::npos : slash - p));
        if (slash == std::string::npos) break;
        p = slash + 1;
    }
    int depth = 0;
    size_t i = 0;
    int found = -1;
    for (size_t k = 0; k < parts.size(); k++) {
        found = -1;
        for (; i < entries.size(); i++) {
            if (entries[i].depth < depth) return -1;
            if (entries[i].depth == depth && entries[i].text == parts[k]) {
                found = static_cast<int>(i);
                i++;
                break;
            }
        }
        if (found < 0) return -1;
        depth++;
    }
    return found;
}

// The id of the item at the path, when it and the menus it is in are
// enabled, or -1.
inline int klioMenuEnabledItem(const std::vector<KlioMenuEntry>& entries, const std::string& path) {
    const int index = klioMenuFindPath(entries, path);
    if (index < 0) return -1;
    const KlioMenuEntry& item = entries[static_cast<size_t>(index)];
    if (!item.enabled || item.kind == 'm' || item.kind == 's') return -1;
    int depth = item.depth;
    for (int i = index - 1; i >= 0 && depth > 0; i--) {
        if (entries[static_cast<size_t>(i)].depth == depth - 1) {
            if (!entries[static_cast<size_t>(i)].enabled) return -1;
            depth--;
        }
    }
    return item.id;
}

// Debug: $KLIO_MENU_DUMP prints a menu bar's entries on stderr.
inline void klioDumpMenuEntries(const std::vector<KlioMenuEntry>& entries) {
    if (!std::getenv("KLIO_MENU_DUMP") || entries.empty()) return;
    std::fprintf(stderr, "[menu] menu bar\n");
    for (const KlioMenuEntry& e : entries) {
        std::string line(static_cast<size_t>(e.depth) * 2, ' ');
        if (e.kind == 's') {
            line += "---";
        } else {
            line += e.text;
            if (!e.enabled) line += " [disabled]";
            if (e.state) line += " [on]";
            if (e.keycode) {
                char buf[48];
                std::snprintf(buf, sizeof buf, " [key %d mods %d]", e.keycode, e.mods);
                line += buf;
            }
        }
        std::fprintf(stderr, "[menu] %s\n", line.c_str());
    }
}

// The texts scripted input carries (a menu path), by index.
inline std::vector<std::string>& klioScriptTexts() {
    static std::vector<std::string> texts;
    return texts;
}

// A window's placement, as Compose Desktop's WindowPlacement orders it.
enum {
    KLIO_PLACEMENT_FLOATING = 0,
    KLIO_PLACEMENT_MAXIMIZED = 1,
    KLIO_PLACEMENT_FULLSCREEN = 2,
};

// What klio_win_set_flag sets.
enum {
    KLIO_WIN_RESIZABLE = 0,
    KLIO_WIN_DECORATED = 1,
    KLIO_WIN_ALWAYS_ON_TOP = 2,
    KLIO_WIN_VISIBLE = 3,
    KLIO_WIN_MINIMIZED = 4,
    KLIO_WIN_PLACEMENT = 5,
    // Brings the window to the front and gives it the keyboard (the value is
    // ignored), as a modal dialog is when its blocked window is clicked.
    KLIO_WIN_FRONT = 6,
    // Makes the window's unpainted pixels see-through: the window composites
    // its frame's alpha over what is behind it.
    KLIO_WIN_TRANSPARENT = 7,
};

enum {
    KLIO_PTR_PRESS = 1,
    KLIO_PTR_RELEASE = 2,
    KLIO_PTR_MOVE = 3,
    KLIO_PTR_ENTER = 4,
    KLIO_PTR_EXIT = 5,
    KLIO_PTR_SCROLL = 6,
};

enum {
    KLIO_BTN_NONE = 0,
    KLIO_BTN_PRIMARY = 1,
    KLIO_BTN_SECONDARY = 2,
    KLIO_BTN_TERTIARY = 3,
    KLIO_BTN_BACK = 4,
    KLIO_BTN_FORWARD = 5,
};

enum {
    KLIO_MOD_SHIFT = 1,
    KLIO_MOD_CTRL = 2,
    KLIO_MOD_ALT = 4,
    KLIO_MOD_META = 8,
    KLIO_MOD_ALT_GRAPH = 16,
    KLIO_MOD_CAPS_LOCK = 32,
    KLIO_MOD_NUM_LOCK = 64,
    KLIO_MOD_SCROLL_LOCK = 128,
    KLIO_MOD_FUNCTION = 256,
};

constexpr int KLIO_EV_VALUES = 12;
constexpr int KLIO_CHAR_UNDEFINED = 0xFFFF;

struct KlioEv {
    int type = KLIO_EV_NONE;
    double v[KLIO_EV_VALUES] = {};
};

// AWT's key locations.
enum {
    KLIO_LOC_STANDARD = 1,
    KLIO_LOC_LEFT = 2,
    KLIO_LOC_RIGHT = 3,
    KLIO_LOC_NUMPAD = 4,
};

// AWT's virtual key codes (java.awt.event.KeyEvent.VK_*) the backends map to.
enum {
    VKK_UNDEFINED = 0,
    VKK_CANCEL = 3,
    VKK_BACK_SPACE = 8,
    VKK_TAB = 9,
    VKK_ENTER = 10,
    VKK_CLEAR = 12,
    VKK_SHIFT = 16,
    VKK_CONTROL = 17,
    VKK_ALT = 18,
    VKK_PAUSE = 19,
    VKK_CAPS_LOCK = 20,
    VKK_ESCAPE = 27,
    VKK_SPACE = 32,
    VKK_PAGE_UP = 33,
    VKK_PAGE_DOWN = 34,
    VKK_END = 35,
    VKK_HOME = 36,
    VKK_LEFT = 37,
    VKK_UP = 38,
    VKK_RIGHT = 39,
    VKK_DOWN = 40,
    VKK_COMMA = 44,
    VKK_MINUS = 45,
    VKK_PERIOD = 46,
    VKK_SLASH = 47,
    VKK_0 = 48,
    VKK_SEMICOLON = 59,
    VKK_EQUALS = 61,
    VKK_A = 65,
    VKK_OPEN_BRACKET = 91,
    VKK_BACK_SLASH = 92,
    VKK_CLOSE_BRACKET = 93,
    VKK_NUMPAD0 = 96,
    VKK_MULTIPLY = 106,
    VKK_ADD = 107,
    VKK_SEPARATOR = 108,
    VKK_SUBTRACT = 109,
    VKK_DECIMAL = 110,
    VKK_DIVIDE = 111,
    VKK_F1 = 112,
    VKK_DELETE = 127,
    VKK_NUM_LOCK = 144,
    VKK_SCROLL_LOCK = 145,
    VKK_PRINTSCREEN = 154,
    VKK_INSERT = 155,
    VKK_HELP = 156,
    VKK_META = 157,
    VKK_BACK_QUOTE = 192,
    VKK_QUOTE = 222,
    VKK_ALT_GRAPH = 65406,
    VKK_F13 = 61440,
    VKK_WINDOWS = 524,
    VKK_CONTEXT_MENU = 525,
};

// F1..F12 are consecutive from 112, F13..F24 from 61440.
inline int klioVkFunction(int n) { return n <= 12 ? VKK_F1 + n - 1 : VKK_F13 + n - 13; }

inline KlioEv klioPointerEv(int kind, double x, double y, int button, int buttons, int mods,
                            double scrollX = 0, double scrollY = 0) {
    KlioEv e;
    e.type = KLIO_EV_POINTER;
    e.v[0] = kind;
    e.v[1] = x;
    e.v[2] = y;
    e.v[3] = scrollX;
    e.v[4] = scrollY;
    e.v[5] = button;
    e.v[6] = buttons;
    e.v[7] = mods;
    return e;
}

inline KlioEv klioKeyEv(bool pressed, int code, int location, int keyChar, int mods) {
    KlioEv e;
    e.type = KLIO_EV_KEY;
    e.v[0] = pressed ? 1 : 2;
    e.v[1] = code;
    e.v[2] = location;
    e.v[3] = keyChar;
    e.v[7] = mods;
    return e;
}

inline KlioEv klioSimpleEv(int type, double a = 0, double b = 0) {
    KlioEv e;
    e.type = type;
    e.v[0] = a;
    e.v[1] = b;
    return e;
}

// A window's frame and placement as last reported, so a change is reported once.
struct KlioFrameReport {
    bool reported = false;
    int x = 0;
    int y = 0;
    int placement = KLIO_PLACEMENT_FLOATING;
    bool minimized = false;
};

// Queues a move and a placement event for what changed since the last report.
inline void klioReportFrame(KlioFrameReport& r, std::deque<KlioEv>& q, int x, int y, int placement,
                            bool minimized) {
    if (!r.reported || x != r.x || y != r.y) q.push_back(klioSimpleEv(KLIO_EV_MOVE, x, y));
    if (!r.reported || placement != r.placement || minimized != r.minimized) {
        q.push_back(klioSimpleEv(KLIO_EV_PLACEMENT, placement, minimized ? 1 : 0));
    }
    r.reported = true;
    r.x = x;
    r.y = y;
    r.placement = placement;
    r.minimized = minimized;
}

// A move the program made: the window's frame now, recorded as reported so
// the move is not reported back later, when the program may have moved it
// again (the desktop reports its own moves before the program's next frame).
// Where the platform put the window elsewhere than asked, that is reported.
inline void klioBaselineMove(KlioFrameReport& r, std::deque<KlioEv>& q, int askedX, int askedY, int x, int y,
                             int placement, bool minimized) {
    if (x != askedX || y != askedY) q.push_back(klioSimpleEv(KLIO_EV_MOVE, x, y));
    r.reported = true;
    r.x = x;
    r.y = y;
    r.placement = placement;
    r.minimized = minimized;
}

// Whether a typed code point is text a field inserts: not a control character,
// the undefined character or one of the Specials, as the desktop's check is.
inline bool klioIsPrintable(unsigned cp) {
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return false;
    if (cp >= 0xFFF0 && cp <= 0xFFFF) return false;
    return true;
}

// Queues the typed code points of UTF-8 text as text events of at most ten.
inline void klioPushText(std::deque<KlioEv>& q, const char* utf8) {
    KlioEv e;
    e.type = KLIO_EV_TEXT;
    int n = 0;
    const unsigned char* s = reinterpret_cast<const unsigned char*>(utf8);
    while (*s) {
        unsigned cp;
        int len;
        if (*s < 0x80) {
            cp = *s;
            len = 1;
        } else if ((*s & 0xE0) == 0xC0) {
            cp = *s & 0x1F;
            len = 2;
        } else if ((*s & 0xF0) == 0xE0) {
            cp = *s & 0x0F;
            len = 3;
        } else {
            cp = *s & 0x07;
            len = 4;
        }
        int i = 1;
        for (; i < len && s[i]; i++) cp = (cp << 6) | (s[i] & 0x3F);
        s += i;
        if (!klioIsPrintable(cp)) continue;
        e.v[1 + n++] = cp;
        if (n == 10) {
            e.v[0] = n;
            q.push_back(e);
            e = KlioEv();
            e.type = KLIO_EV_TEXT;
            n = 0;
        }
    }
    if (n > 0) {
        e.v[0] = n;
        q.push_back(e);
    }
}

// Pops the next queued event into out (type, then the values); the type, or
// KLIO_EV_NONE when the queue is empty.
inline int klioPopEv(std::deque<KlioEv>& q, double* out) {
    if (q.empty()) return KLIO_EV_NONE;
    const KlioEv e = q.front();
    q.pop_front();
    if (out) {
        for (int i = 0; i < KLIO_EV_VALUES; i++) out[i] = e.v[i];
    }
    return e.type;
}

// A macOS virtual key code (the kVK_* of HIToolbox, by position on an ANSI
// keyboard) as AWT's key code and location, as the JDK's macOS toolkit maps it.
inline void klioMacKey(unsigned short code, int* vk, int* loc) {
    *loc = KLIO_LOC_STANDARD;
    static const int letters[] = {
        // 0x00..0x32
        'A', 'S', 'D', 'F', 'H', 'G', 'Z', 'X', 'C', 'V', 0, 'B', 'Q', 'W', 'E', 'R',
        'Y', 'T', '1', '2', '3', '4', '6', '5', VKK_EQUALS, '9', '7', VKK_MINUS, '8', '0',
        VKK_CLOSE_BRACKET, 'O', 'U', VKK_OPEN_BRACKET, 'I', 'P', VKK_ENTER, 'L', 'J', VKK_QUOTE,
        'K', VKK_SEMICOLON, VKK_BACK_SLASH, VKK_COMMA, VKK_SLASH, 'N', 'M', VKK_PERIOD, VKK_TAB,
        VKK_SPACE, VKK_BACK_QUOTE,
    };
    if (code <= 0x32) {
        *vk = letters[code];
        return;
    }
    switch (code) {
        case 0x33: *vk = VKK_BACK_SPACE; return;
        case 0x35: *vk = VKK_ESCAPE; return;
        case 0x36: *vk = VKK_META; *loc = KLIO_LOC_RIGHT; return;
        case 0x37: *vk = VKK_META; *loc = KLIO_LOC_LEFT; return;
        case 0x38: *vk = VKK_SHIFT; *loc = KLIO_LOC_LEFT; return;
        case 0x39: *vk = VKK_CAPS_LOCK; return;
        case 0x3A: *vk = VKK_ALT; *loc = KLIO_LOC_LEFT; return;
        case 0x3B: *vk = VKK_CONTROL; *loc = KLIO_LOC_LEFT; return;
        case 0x3C: *vk = VKK_SHIFT; *loc = KLIO_LOC_RIGHT; return;
        case 0x3D: *vk = VKK_ALT; *loc = KLIO_LOC_RIGHT; return;
        case 0x3E: *vk = VKK_CONTROL; *loc = KLIO_LOC_RIGHT; return;
        case 0x40: *vk = klioVkFunction(17); return;
        case 0x41: *vk = VKK_DECIMAL; *loc = KLIO_LOC_NUMPAD; return;
        case 0x43: *vk = VKK_MULTIPLY; *loc = KLIO_LOC_NUMPAD; return;
        case 0x45: *vk = VKK_ADD; *loc = KLIO_LOC_NUMPAD; return;
        case 0x47: *vk = VKK_CLEAR; *loc = KLIO_LOC_NUMPAD; return;
        case 0x4B: *vk = VKK_DIVIDE; *loc = KLIO_LOC_NUMPAD; return;
        case 0x4C: *vk = VKK_ENTER; *loc = KLIO_LOC_NUMPAD; return;
        case 0x4E: *vk = VKK_SUBTRACT; *loc = KLIO_LOC_NUMPAD; return;
        case 0x4F: *vk = klioVkFunction(18); return;
        case 0x50: *vk = klioVkFunction(19); return;
        case 0x51: *vk = VKK_EQUALS; *loc = KLIO_LOC_NUMPAD; return;
        case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57: case 0x58: case 0x59:
            *vk = VKK_NUMPAD0 + (code - 0x52);
            *loc = KLIO_LOC_NUMPAD;
            return;
        case 0x5A: *vk = klioVkFunction(20); return;
        case 0x5B: *vk = VKK_NUMPAD0 + 8; *loc = KLIO_LOC_NUMPAD; return;
        case 0x5C: *vk = VKK_NUMPAD0 + 9; *loc = KLIO_LOC_NUMPAD; return;
        case 0x60: *vk = klioVkFunction(5); return;
        case 0x61: *vk = klioVkFunction(6); return;
        case 0x62: *vk = klioVkFunction(7); return;
        case 0x63: *vk = klioVkFunction(3); return;
        case 0x64: *vk = klioVkFunction(8); return;
        case 0x65: *vk = klioVkFunction(9); return;
        case 0x67: *vk = klioVkFunction(11); return;
        case 0x69: *vk = klioVkFunction(13); return;
        case 0x6A: *vk = klioVkFunction(16); return;
        case 0x6B: *vk = klioVkFunction(14); return;
        case 0x6D: *vk = klioVkFunction(10); return;
        case 0x6F: *vk = klioVkFunction(12); return;
        case 0x71: *vk = klioVkFunction(15); return;
        case 0x72: *vk = VKK_HELP; return;
        case 0x73: *vk = VKK_HOME; return;
        case 0x74: *vk = VKK_PAGE_UP; return;
        case 0x75: *vk = VKK_DELETE; return;
        case 0x76: *vk = klioVkFunction(4); return;
        case 0x77: *vk = VKK_END; return;
        case 0x78: *vk = klioVkFunction(2); return;
        case 0x79: *vk = VKK_PAGE_DOWN; return;
        case 0x7A: *vk = klioVkFunction(1); return;
        case 0x7B: *vk = VKK_LEFT; return;
        case 0x7C: *vk = VKK_RIGHT; return;
        case 0x7D: *vk = VKK_DOWN; return;
        case 0x7E: *vk = VKK_UP; return;
        default: *vk = VKK_UNDEFINED; return;
    }
}

// The character AWT gives a key's pressed and released events: the character
// the key types, with the few keys whose platform character differs mapped to
// AWT's, and none for keys that type nothing.
inline int klioAwtKeyChar(int vk, unsigned platformChar) {
    switch (vk) {
        case VKK_ENTER: return '\n';
        case VKK_BACK_SPACE: return '\b';
        case VKK_TAB: return '\t';
        case VKK_ESCAPE: return 0x1B;
        case VKK_DELETE: return 0x7F;
        default: break;
    }
    if (platformChar == 0 || (platformChar >= 0xF700 && platformChar <= 0xF8FF)) {
        return KLIO_CHAR_UNDEFINED;
    }
    return static_cast<int>(platformChar);
}

// Scripted input: $KLIO_WIN_INPUT names a file of events to queue on a window
// as if its platform had sent them, so a program's window can be driven and
// its frames checked (KLIO_SKIA_DUMP_AT). An event comes at the window's n-th
// event poll, or t milliseconds after its first ("<t>ms"). One event per
// line, '#' starting a comment:
//   <when> move <x> <y>
//   <when> press <x> <y> [button]        (1 primary, 2 secondary, 3 tertiary, ...)
//   <when> release <x> <y> [button]
//   <when> scroll <x> <y> <dx> <dy>
//   <when> key <code> [char] [mods]      a press and release of an AWT key code;
//                                        "menu" after it adds the platform's menu
//                                        shortcut modifier (Command on macOS,
//                                        Control elsewhere, as AWT's Toolkit has it)
//   <when> text <characters>             typed text, the rest of the line
//   <when> focus <0|1>                   the window gains or loses the focus; a script
//                                        with a focus event is the windows' only source
//                                        of focus, the platform's own changes dropped
//   <when> close                         the window's close button: a close request
//   <when> menu <path>                   choose the menu bar item at the path of
//                                        titles ("File/Open"), as a click would
//   <when> menushow <path>               open the drawn menus down to the item at
//                                        the path and leave them open (an SDL
//                                        window's menu bar, for frame dumps;
//                                        native menu bars ignore it)
//   <when> tray action                   a tray icon's action
//   <when> tray menu <path>              choose the tray menu's item at the path
// A tray's events count its own polls and time, apart from the windows'.
// The modifier of the platform's menu shortcuts (copy, paste, select all).
inline int klioMenuShortcutMod() {
#if defined(__APPLE__)
    return KLIO_MOD_META;
#else
    return KLIO_MOD_CTRL;
#endif
}

// Whether the script gives the windows their focus: a script with a focus
// event is the only source of focus changes, so a window driven by it sees
// the same ones whichever other windows open beside it.
inline bool klioScriptDrivesFocus();

struct KlioScriptEntry {
    int poll;       // the poll it comes at, or -1 for a timed one
    long long ms;   // milliseconds after the first poll, for a timed one
    KlioEv ev;
    bool tray;      // a tray's event, not a window's
};

inline std::vector<KlioScriptEntry>& klioScript() {
    static std::vector<KlioScriptEntry> script;
    static bool loaded = false;
    if (loaded) return script;
    loaded = true;
    const char* path = std::getenv("KLIO_WIN_INPUT");
    if (!path) return script;
    FILE* f = std::fopen(path, "r");
    if (!f) return script;
    char line[1024];
    int held = 0;
    while (std::fgets(line, sizeof line, f)) {
        line[std::strcspn(line, "\r\n")] = 0;
        if (line[0] == '#' || line[0] == 0) continue;
        char when[32] = {};
        char cmd[16] = {};
        int used = 0;
        if (std::sscanf(line, "%31s %15s %n", when, cmd, &used) < 2) continue;
        int poll = -1;
        long long ms = 0;
        const size_t wlen = std::strlen(when);
        if (wlen > 2 && std::strcmp(when + wlen - 2, "ms") == 0) {
            ms = std::atoll(when);
        } else {
            poll = std::atoi(when);
        }
        auto add = [&](const KlioEv& e) { script.push_back({poll, ms, e, false}); };
        auto addTray = [&](const KlioEv& e) { script.push_back({poll, ms, e, true}); };
        const char* rest = line + used;
        double a = 0, b = 0, c = 0, d = 0;
        const int n = std::sscanf(rest, "%lf %lf %lf %lf", &a, &b, &c, &d);
        if (std::strcmp(cmd, "move") == 0) {
            add(klioPointerEv(KLIO_PTR_MOVE, a, b, KLIO_BTN_NONE, held, 0));
        } else if (std::strcmp(cmd, "press") == 0 || std::strcmp(cmd, "release") == 0) {
            const int button = n >= 3 ? static_cast<int>(c) : KLIO_BTN_PRIMARY;
            const bool press = cmd[0] == 'p';
            if (press) held |= 1 << (button - 1);
            else held &= ~(1 << (button - 1));
            add(klioPointerEv(press ? KLIO_PTR_PRESS : KLIO_PTR_RELEASE, a, b, button, held, 0));
        } else if (std::strcmp(cmd, "scroll") == 0) {
            add(klioPointerEv(KLIO_PTR_SCROLL, a, b, KLIO_BTN_NONE, held, 0, c, d));
        } else if (std::strcmp(cmd, "key") == 0) {
            const int code = static_cast<int>(a);
            const int ch = n >= 2 ? static_cast<int>(b) : KLIO_CHAR_UNDEFINED;
            int mods = n >= 3 ? static_cast<int>(c) : 0;
            if (std::strstr(rest, "menu")) mods |= klioMenuShortcutMod();
            add(klioKeyEv(true, code, KLIO_LOC_STANDARD, ch, mods));
            add(klioKeyEv(false, code, KLIO_LOC_STANDARD, ch, mods));
        } else if (std::strcmp(cmd, "text") == 0) {
            std::deque<KlioEv> typed;
            klioPushText(typed, rest);
            for (const KlioEv& e : typed) add(e);
        } else if (std::strcmp(cmd, "focus") == 0) {
            add(klioSimpleEv(KLIO_EV_FOCUS, a));
        } else if (std::strcmp(cmd, "close") == 0) {
            add(klioSimpleEv(KLIO_EV_CLOSE));
        } else if (std::strcmp(cmd, "menu") == 0 || std::strcmp(cmd, "menushow") == 0) {
            klioScriptTexts().push_back(rest);
            add(klioSimpleEv(KLIO_EV_MENU_PATH, static_cast<double>(klioScriptTexts().size() - 1),
                             cmd[4] == 's' ? 1 : 0));
        } else if (std::strcmp(cmd, "tray") == 0) {
            if (std::strncmp(rest, "action", 6) == 0) {
                addTray(klioSimpleEv(KLIO_EV_TRAY_ACTION));
            } else if (std::strncmp(rest, "menu ", 5) == 0) {
                klioScriptTexts().push_back(rest + 5);
                addTray(klioSimpleEv(KLIO_EV_MENU_PATH, static_cast<double>(klioScriptTexts().size() - 1)));
            }
        }
    }
    std::fclose(f);
    return script;
}

inline bool klioScriptDrivesFocus() {
    static const bool drives = [] {
        for (const KlioScriptEntry& e : klioScript()) {
            if (!e.tray && e.ev.type == KLIO_EV_FOCUS) return true;
        }
        return false;
    }();
    return drives;
}

// A window's progress through the script: its polls, when the first came,
// and which timed events it has queued.
struct KlioScriptState {
    int polls = 0;
    std::chrono::steady_clock::time_point start;
    size_t nextTimed = 0;
};

// Counts a window's event poll and queues the scripted events due at it:
// those of this poll, and the timed ones whose time has come, in order.
inline void klioScriptTick(KlioScriptState& st, std::deque<KlioEv>& q, bool tray = false) {
    const auto& script = klioScript();
    if (script.empty()) return;
    const int n = ++st.polls;
    if (n == 1) st.start = std::chrono::steady_clock::now();
    const long long elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - st.start).count();
    size_t timed = 0;
    bool waiting = false;  // a timed event not yet due holds back the ones after it
    for (const KlioScriptEntry& e : script) {
        if (e.tray != tray) continue;
        if (e.poll == n) q.push_back(e.ev);
        if (e.poll >= 0) continue;
        if (timed++ < st.nextTimed || waiting) continue;
        if (e.ms > elapsed) {
            waiting = true;
            continue;
        }
        q.push_back(e.ev);
        st.nextTimed++;
    }
}
