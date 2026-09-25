/*
 * Copyright 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// ui's Key, taken from the desktop actual (Key.desktop.kt), which numbers the
// keys by the desktop's key codes and names them by the desktop's key texts;
// the codes and texts are written in here, where desktop reads them from
// java.awt.event.KeyEvent.
package androidx.compose.ui.input.key

import androidx.compose.ui.input.key.Key.Companion.Number
import androidx.compose.ui.util.packInts
import androidx.compose.ui.util.unpackInt1
import androidx.compose.ui.util.unpackInt2

// TODO(demin): implement most of key codes

/**
 * Actual implementation of [Key] for Desktop.
 *
 * @param keyCode an integer code representing the key pressed. Note: This keycode can be used to
 * uniquely identify a hardware key. It is different from the native keycode.
 */
@JvmInline
actual value class Key(val keyCode: Long) {
    actual companion object {
        /** Unknown key. */
        actual val Unknown = Key(0)

        /**
         * System Home key.
         *
         * This key is handled by the framework and is never delivered to applications.
         */
        @Deprecated(
            "`Key.Home` was mapped to the keyboard \"Home\" key in error. It is meant to be the" +
                " \"system\" home key on Android, and should never be delivered to applications. " +
                "For the keyboard \"Home\" key use `Key.MoveHome`. For the Android system " +
                "\"Home\" key (unlikely to be needed), use `Key.SystemHome`",
            level = DeprecationLevel.ERROR,
        )
        actual val Home = Key(36)

        /**
         * System Home key.
         *
         * This key is handled by the framework and is never delivered to applications.
         */
        actual val SystemHome: Key = Key(-1000000184)

        /** Help key. */
        actual val Help = Key(156)

        /**
         * Up Arrow Key / Directional Pad Up key.
         *
         * May also be synthesized from trackball motions.
         */
        actual val DirectionUp = Key(38)

        /**
         * Down Arrow Key / Directional Pad Down key.
         *
         * May also be synthesized from trackball motions.
         */
        actual val DirectionDown = Key(40)

        /**
         * Left Arrow Key / Directional Pad Left key.
         *
         * May also be synthesized from trackball motions.
         */
        actual val DirectionLeft = Key(37)

        /**
         * Right Arrow Key / Directional Pad Right key.
         *
         * May also be synthesized from trackball motions.
         */
        actual val DirectionRight = Key(39)

        /** '0' key. */
        actual val Zero = Key(48)

        /** '1' key. */
        actual val One = Key(49)

        /** '2' key. */
        actual val Two = Key(50)

        /** '3' key. */
        actual val Three = Key(51)

        /** '4' key. */
        actual val Four = Key(52)

        /** '5' key. */
        actual val Five = Key(53)

        /** '6' key. */
        actual val Six = Key(54)

        /** '7' key. */
        actual val Seven = Key(55)

        /** '8' key. */
        actual val Eight = Key(56)

        /** '9' key. */
        actual val Nine = Key(57)

        /** '+' key. */
        actual val Plus = Key(521)

        /** '-' key. */
        actual val Minus = Key(45)

        /** '*' key. */
        actual val Multiply = Key(106)

        /** '=' key. */
        actual val Equals = Key(61)

        /** '#' key. */
        actual val Pound = Key(520)

        /** 'A' key. */
        actual val A = Key(65)

        /** 'B' key. */
        actual val B = Key(66)

        /** 'C' key. */
        actual val C = Key(67)

        /** 'D' key. */
        actual val D = Key(68)

        /** 'E' key. */
        actual val E = Key(69)

        /** 'F' key. */
        actual val F = Key(70)

        /** 'G' key. */
        actual val G = Key(71)

        /** 'H' key. */
        actual val H = Key(72)

        /** 'I' key. */
        actual val I = Key(73)

        /** 'J' key. */
        actual val J = Key(74)

        /** 'K' key. */
        actual val K = Key(75)

        /** 'L' key. */
        actual val L = Key(76)

        /** 'M' key. */
        actual val M = Key(77)

        /** 'N' key. */
        actual val N = Key(78)

        /** 'O' key. */
        actual val O = Key(79)

        /** 'P' key. */
        actual val P = Key(80)

        /** 'Q' key. */
        actual val Q = Key(81)

        /** 'R' key. */
        actual val R = Key(82)

        /** 'S' key. */
        actual val S = Key(83)

        /** 'T' key. */
        actual val T = Key(84)

        /** 'U' key. */
        actual val U = Key(85)

        /** 'V' key. */
        actual val V = Key(86)

        /** 'W' key. */
        actual val W = Key(87)

        /** 'X' key. */
        actual val X = Key(88)

        /** 'Y' key. */
        actual val Y = Key(89)

        /** 'Z' key. */
        actual val Z = Key(90)

        /** ',' key. */
        actual val Comma = Key(44)

        /** '.' key. */
        actual val Period = Key(46)

        /** Left Alt modifier key. */
        actual val AltLeft = Key(18, KEY_LOCATION_LEFT)

        /** Right Alt modifier key. */
        actual val AltRight = Key(18, KEY_LOCATION_RIGHT)

        /** Left Shift modifier key. */
        actual val ShiftLeft = Key(16, KEY_LOCATION_LEFT)

        /** Right Shift modifier key. */
        actual val ShiftRight = Key(16, KEY_LOCATION_RIGHT)

        /** Tab key. */
        actual val Tab = Key(9)

        /** Space key. */
        actual val Spacebar = Key(32)

        /** Enter key. */
        actual val Enter = Key(10)

        /**
         * Backspace key.
         *
         * Deletes characters before the insertion point, unlike [Delete].
         */
        actual val Backspace = Key(8)

        /**
         * Delete key.
         *
         * Deletes characters ahead of the insertion point, unlike [Backspace].
         */
        actual val Delete = Key(127)

        /** Escape key. */
        actual val Escape = Key(27)

        /** Left Control modifier key. */
        actual val CtrlLeft = Key(17, KEY_LOCATION_LEFT)

        /** Right Control modifier key. */
        actual val CtrlRight = Key(17, KEY_LOCATION_RIGHT)

        /** Caps Lock key. */
        actual val CapsLock = Key(20)

        /** Scroll Lock key. */
        actual val ScrollLock = Key(145)

        /** Left Meta modifier key. */
        actual val MetaLeft = Key(157, KEY_LOCATION_LEFT)

        /** Right Meta modifier key. */
        actual val MetaRight = Key(157, KEY_LOCATION_RIGHT)

        /** System Request / Print Screen key. */
        actual val PrintScreen = Key(154)

        /**
         * Home Movement key.
         *
         * Used for scrolling or moving the cursor around to the start of a line or to the top of a
         * list.
         */
        actual val MoveHome = Key(36)

        /**
         * End Movement key.
         *
         * Used for scrolling or moving the cursor around to the end of a line or to the bottom of a
         * list.
         */
        actual val MoveEnd = Key(35)

        /**
         * Insert key.
         *
         * Toggles insert / overwrite edit mode.
         */
        actual val Insert = Key(155)

        /** Cut key. */
        actual val Cut = Key(65489)

        /** Copy key. */
        actual val Copy = Key(65485)

        /** Paste key. */
        actual val Paste = Key(65487)

        /** '`' (backtick) key. */
        actual val Grave = Key(192)

        /** '[' key. */
        actual val LeftBracket = Key(91)

        /** ']' key. */
        actual val RightBracket = Key(93)

        /** '/' key. */
        actual val Slash = Key(47)

        /** '\' key. */
        actual val Backslash = Key(92)

        /** ';' key. */
        actual val Semicolon = Key(59)

        /** ''' (apostrophe) key. */
        actual val Apostrophe = Key(222)

        /** '@' key. */
        actual val At = Key(512)

        /** Page Up key. */
        actual val PageUp = Key(33)

        /** Page Down key. */
        actual val PageDown = Key(34)

        /** F1 key. */
        actual val F1 = Key(112)

        /** F2 key. */
        actual val F2 = Key(113)

        /** F3 key. */
        actual val F3 = Key(114)

        /** F4 key. */
        actual val F4 = Key(115)

        /** F5 key. */
        actual val F5 = Key(116)

        /** F6 key. */
        actual val F6 = Key(117)

        /** F7 key. */
        actual val F7 = Key(118)

        /** F8 key. */
        actual val F8 = Key(119)

        /** F9 key. */
        actual val F9 = Key(120)

        /** F10 key. */
        actual val F10 = Key(121)

        /** F11 key. */
        actual val F11 = Key(122)

        /** F12 key. */
        actual val F12 = Key(123)

        /**
         * Num Lock key.
         *
         * This is the Num Lock key; it is different from [Number].
         * This key alters the behavior of other keys on the numeric keypad.
         */
        actual val NumLock = Key(144, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '0' key. */
        actual val NumPad0 = Key(96, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '1' key. */
        actual val NumPad1 = Key(97, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '2' key. */
        actual val NumPad2 = Key(98, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '3' key. */
        actual val NumPad3 = Key(99, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '4' key. */
        actual val NumPad4 = Key(100, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '5' key. */
        actual val NumPad5 = Key(101, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '6' key. */
        actual val NumPad6 = Key(102, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '7' key. */
        actual val NumPad7 = Key(103, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '8' key. */
        actual val NumPad8 = Key(104, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '9' key. */
        actual val NumPad9 = Key(105, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '/' key (for division). */
        actual val NumPadDivide = Key(111, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '*' key (for multiplication). */
        actual val NumPadMultiply = Key(106, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '-' key (for subtraction). */
        actual val NumPadSubtract = Key(109, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '+' key (for addition). */
        actual val NumPadAdd = Key(107, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '.' key (for decimals or digit grouping). */
        actual val NumPadDot = Key(110, KEY_LOCATION_NUMPAD)

        /** Numeric keypad ',' key (for decimals or digit grouping). */
        actual val NumPadComma = Key(44, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Enter key. */
        actual val NumPadEnter = Key(10, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '=' key. */
        actual val NumPadEquals = Key(61, KEY_LOCATION_NUMPAD)

        /** Numeric keypad '(' key. */
        actual val NumPadLeftParenthesis = Key(519, KEY_LOCATION_NUMPAD)

        /** Numeric keypad ')' key. */
        actual val NumPadRightParenthesis = Key(522, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Up Arrow Key. */
        actual val NumPadDirectionUp = Key(38, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Down Arrow Key. */
        actual val NumPadDirectionDown = Key(40, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Left Arrow Key. */
        actual val NumPadDirectionLeft = Key(37, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Right Arrow Key. */
        actual val NumPadDirectionRight = Key(39, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Home Key. */
        actual val NumPadMoveHome: Key = Key(36, KEY_LOCATION_NUMPAD)

        /** Numeric keypad End Key. */
        actual val NumPadMoveEnd = Key(35, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Page Up Key. */
        actual val NumPadPageUp = Key(33, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Page Down Key. */
        actual val NumPadPageDown = Key(34, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Insert Key. */
        actual val NumPadInsert = Key(155, KEY_LOCATION_NUMPAD)

        /** Numeric keypad Delete Key. */
        actual val NumPadDelete: Key = Key(127, KEY_LOCATION_NUMPAD)

        // Unsupported Keys. These keys will never be sent by the desktop. However we need unique
        // keycodes so that these constants can be used in a when statement without a warning.
        actual val SoftLeft = Key(-1000000001)
        actual val SoftRight = Key(-1000000002)
        actual val Back = Key(-1000000003)
        actual val NavigatePrevious = Key(-1000000004)
        actual val NavigateNext = Key(-1000000005)
        actual val NavigateIn = Key(-1000000006)
        actual val NavigateOut = Key(-1000000007)
        actual val SystemNavigationUp = Key(-1000000008)
        actual val SystemNavigationDown = Key(-1000000009)
        actual val SystemNavigationLeft = Key(-1000000010)
        actual val SystemNavigationRight = Key(-1000000011)
        actual val Call = Key(-1000000012)
        actual val EndCall = Key(-1000000013)
        actual val DirectionCenter = Key(-1000000014)
        actual val DirectionUpLeft = Key(-1000000015)
        actual val DirectionDownLeft = Key(-1000000016)
        actual val DirectionUpRight = Key(-1000000017)
        actual val DirectionDownRight = Key(-1000000018)
        actual val VolumeUp = Key(-1000000019)
        actual val VolumeDown = Key(-1000000020)
        actual val Power = Key(-1000000021)
        actual val Camera = Key(-1000000022)
        actual val Clear = Key(-1000000023)
        actual val Symbol = Key(-1000000024)
        actual val Browser = Key(-1000000025)
        actual val Envelope = Key(-1000000026)
        actual val Function = Key(-1000000027)
        actual val Break = Key(-1000000028)
        actual val Number = Key(-1000000031)
        actual val HeadsetHook = Key(-1000000032)
        actual val Focus = Key(-1000000033)
        actual val Menu = Key(-1000000034)
        actual val Notification = Key(-1000000035)
        actual val Search = Key(-1000000036)
        actual val PictureSymbols = Key(-1000000037)
        actual val SwitchCharset = Key(-1000000038)
        actual val ButtonA = Key(-1000000039)
        actual val ButtonB = Key(-1000000040)
        actual val ButtonC = Key(-1000000041)
        actual val ButtonX = Key(-1000000042)
        actual val ButtonY = Key(-1000000043)
        actual val ButtonZ = Key(-1000000044)
        actual val ButtonL1 = Key(-1000000045)
        actual val ButtonR1 = Key(-1000000046)
        actual val ButtonL2 = Key(-1000000047)
        actual val ButtonR2 = Key(-1000000048)
        actual val ButtonThumbLeft = Key(-1000000049)
        actual val ButtonThumbRight = Key(-1000000050)
        actual val ButtonStart = Key(-1000000051)
        actual val ButtonSelect = Key(-1000000052)
        actual val ButtonMode = Key(-1000000053)
        actual val Button1 = Key(-1000000054)
        actual val Button2 = Key(-1000000055)
        actual val Button3 = Key(-1000000056)
        actual val Button4 = Key(-1000000057)
        actual val Button5 = Key(-1000000058)
        actual val Button6 = Key(-1000000059)
        actual val Button7 = Key(-1000000060)
        actual val Button8 = Key(-1000000061)
        actual val Button9 = Key(-1000000062)
        actual val Button10 = Key(-1000000063)
        actual val Button11 = Key(-1000000064)
        actual val Button12 = Key(-1000000065)
        actual val Button13 = Key(-1000000066)
        actual val Button14 = Key(-1000000067)
        actual val Button15 = Key(-1000000068)
        actual val Button16 = Key(-1000000069)
        actual val Forward = Key(-1000000070)
        actual val MediaPlay = Key(-1000000071)
        actual val MediaPause = Key(-1000000072)
        actual val MediaPlayPause = Key(-1000000073)
        actual val MediaStop = Key(-1000000074)
        actual val MediaRecord = Key(-1000000075)
        actual val MediaNext = Key(-1000000076)
        actual val MediaPrevious = Key(-1000000077)
        actual val MediaRewind = Key(-1000000078)
        actual val MediaFastForward = Key(-1000000079)
        actual val MediaClose = Key(-1000000080)
        actual val MediaAudioTrack = Key(-1000000081)
        actual val MediaEject = Key(-1000000082)
        actual val MediaTopMenu = Key(-1000000083)
        actual val MediaSkipForward = Key(-1000000084)
        actual val MediaSkipBackward = Key(-1000000085)
        actual val MediaStepForward = Key(-1000000086)
        actual val MediaStepBackward = Key(-1000000087)
        actual val MicrophoneMute = Key(-1000000088)
        actual val VolumeMute = Key(-1000000089)
        actual val Info = Key(-1000000090)
        actual val ChannelUp = Key(-1000000091)
        actual val ChannelDown = Key(-1000000092)
        actual val ZoomIn = Key(-1000000093)
        actual val ZoomOut = Key(-1000000094)
        actual val Tv = Key(-1000000095)
        actual val Window = Key(-1000000096)
        actual val Guide = Key(-1000000097)
        actual val Dvr = Key(-1000000098)
        actual val Bookmark = Key(-1000000099)
        actual val Captions = Key(-1000000100)
        actual val Settings = Key(-1000000101)
        actual val TvPower = Key(-1000000102)
        actual val TvInput = Key(-1000000103)
        actual val SetTopBoxPower = Key(-1000000104)
        actual val SetTopBoxInput = Key(-1000000105)
        actual val AvReceiverPower = Key(-1000000106)
        actual val AvReceiverInput = Key(-1000000107)
        actual val ProgramRed = Key(-1000000108)
        actual val ProgramGreen = Key(-1000000109)
        actual val ProgramYellow = Key(-1000000110)
        actual val ProgramBlue = Key(-1000000111)
        actual val AppSwitch = Key(-1000000112)
        actual val LanguageSwitch = Key(-1000000113)
        actual val MannerMode = Key(-1000000114)
        actual val Toggle2D3D = Key(-1000000125)
        actual val Contacts = Key(-1000000126)
        actual val Calendar = Key(-1000000127)
        actual val Music = Key(-1000000128)
        actual val Calculator = Key(-1000000129)
        actual val ZenkakuHankaru = Key(-1000000130)
        actual val Eisu = Key(-1000000131)
        actual val Muhenkan = Key(-1000000132)
        actual val Henkan = Key(-1000000133)
        actual val KatakanaHiragana = Key(-1000000134)
        actual val Yen = Key(-1000000135)
        actual val Ro = Key(-1000000136)
        actual val Kana = Key(-1000000137)
        actual val Assist = Key(-1000000138)
        actual val BrightnessDown = Key(-1000000139)
        actual val BrightnessUp = Key(-1000000140)
        actual val Sleep = Key(-1000000141)
        actual val WakeUp = Key(-1000000142)
        actual val SoftSleep = Key(-1000000143)
        actual val Pairing = Key(-1000000144)
        actual val LastChannel = Key(-1000000145)
        actual val TvDataService = Key(-1000000146)
        actual val VoiceAssist = Key(-1000000147)
        actual val TvRadioService = Key(-1000000148)
        actual val TvTeletext = Key(-1000000149)
        actual val TvNumberEntry = Key(-1000000150)
        actual val TvTerrestrialAnalog = Key(-1000000151)
        actual val TvTerrestrialDigital = Key(-1000000152)
        actual val TvSatellite = Key(-1000000153)
        actual val TvSatelliteBs = Key(-1000000154)
        actual val TvSatelliteCs = Key(-1000000155)
        actual val TvSatelliteService = Key(-1000000156)
        actual val TvNetwork = Key(-1000000157)
        actual val TvAntennaCable = Key(-1000000158)
        actual val TvInputHdmi1 = Key(-1000000159)
        actual val TvInputHdmi2 = Key(-1000000160)
        actual val TvInputHdmi3 = Key(-1000000161)
        actual val TvInputHdmi4 = Key(-1000000162)
        actual val TvInputComposite1 = Key(-1000000163)
        actual val TvInputComposite2 = Key(-1000000164)
        actual val TvInputComponent1 = Key(-1000000165)
        actual val TvInputComponent2 = Key(-1000000166)
        actual val TvInputVga1 = Key(-1000000167)
        actual val TvAudioDescription = Key(-1000000168)
        actual val TvAudioDescriptionMixingVolumeUp = Key(-1000000169)
        actual val TvAudioDescriptionMixingVolumeDown = Key(-1000000170)
        actual val TvZoomMode = Key(-1000000171)
        actual val TvContentsMenu = Key(-1000000172)
        actual val TvMediaContextMenu = Key(-1000000173)
        actual val TvTimerProgramming = Key(-1000000174)
        actual val StemPrimary = Key(-1000000175)
        actual val Stem1 = Key(-1000000176)
        actual val Stem2 = Key(-1000000177)
        actual val Stem3 = Key(-1000000178)
        actual val AllApps = Key(-1000000179)
        actual val Refresh = Key(-1000000180)
        actual val ThumbsUp = Key(-1000000181)
        actual val ThumbsDown = Key(-1000000182)
        actual val ProfileSwitch = Key(-1000000183)
}

    actual override fun toString(): String {
        return "Key: ${keyText(nativeKeyCode)}"
    }
}

/**
 * Creates instance of [Key].
 *
 * @param nativeKeyCode the key's code, as the desktop numbers keys
 * @param nativeKeyLocation where the key is: standard, left, right or numpad
 */
fun Key(nativeKeyCode: Int, nativeKeyLocation: Int = KEY_LOCATION_STANDARD): Key {
    // Only 3 bits are required for nativeKeyLocation.
    return Key(packInts(nativeKeyLocation, nativeKeyCode))
}

/**
 * The native keycode corresponding to this [Key].
 */
val Key.nativeKeyCode: Int
    get() = unpackInt2(keyCode)

/**
 * The native location corresponding to this [Key].
 */
val Key.nativeKeyLocation: Int
    get() = unpackInt1(keyCode)

private const val KEY_LOCATION_STANDARD = 1
private const val KEY_LOCATION_LEFT = 2
private const val KEY_LOCATION_RIGHT = 3
private const val KEY_LOCATION_NUMPAD = 4

/** Each key code's text, as the desktop names the key on Linux and Windows. */
private val keyTexts: Map<Int, String> = mapOf(
    0 to "Unknown keyCode: 0x0",
    3 to "Cancel",
    8 to "Backspace",
    9 to "Tab",
    10 to "Enter",
    12 to "Clear",
    16 to "Shift",
    17 to "Ctrl",
    18 to "Alt",
    19 to "Pause",
    20 to "Caps Lock",
    21 to "Kana",
    24 to "Final",
    25 to "Kanji",
    27 to "Escape",
    28 to "Convert",
    29 to "No Convert",
    30 to "Accept",
    31 to "Mode Change",
    32 to "Space",
    33 to "Page Up",
    34 to "Page Down",
    35 to "End",
    36 to "Home",
    37 to "Left",
    38 to "Up",
    39 to "Right",
    40 to "Down",
    44 to "Comma",
    45 to "Minus",
    46 to "Period",
    47 to "Slash",
    48 to "0",
    49 to "1",
    50 to "2",
    51 to "3",
    52 to "4",
    53 to "5",
    54 to "6",
    55 to "7",
    56 to "8",
    57 to "9",
    59 to "Semicolon",
    61 to "Equals",
    65 to "A",
    66 to "B",
    67 to "C",
    68 to "D",
    69 to "E",
    70 to "F",
    71 to "G",
    72 to "H",
    73 to "I",
    74 to "J",
    75 to "K",
    76 to "L",
    77 to "M",
    78 to "N",
    79 to "O",
    80 to "P",
    81 to "Q",
    82 to "R",
    83 to "S",
    84 to "T",
    85 to "U",
    86 to "V",
    87 to "W",
    88 to "X",
    89 to "Y",
    90 to "Z",
    91 to "Open Bracket",
    92 to "Back Slash",
    93 to "Close Bracket",
    96 to "NumPad-0",
    97 to "NumPad-1",
    98 to "NumPad-2",
    99 to "NumPad-3",
    100 to "NumPad-4",
    101 to "NumPad-5",
    102 to "NumPad-6",
    103 to "NumPad-7",
    104 to "NumPad-8",
    105 to "NumPad-9",
    106 to "NumPad *",
    107 to "NumPad +",
    108 to "NumPad ,",
    109 to "NumPad -",
    110 to "NumPad .",
    111 to "NumPad /",
    112 to "F1",
    113 to "F2",
    114 to "F3",
    115 to "F4",
    116 to "F5",
    117 to "F6",
    118 to "F7",
    119 to "F8",
    120 to "F9",
    121 to "F10",
    122 to "F11",
    123 to "F12",
    127 to "Delete",
    128 to "Dead Grave",
    129 to "Dead Acute",
    130 to "Dead Circumflex",
    131 to "Dead Tilde",
    132 to "Dead Macron",
    133 to "Dead Breve",
    134 to "Dead Above Dot",
    135 to "Dead Diaeresis",
    136 to "Dead Above Ring",
    137 to "Dead Double Acute",
    138 to "Dead Caron",
    139 to "Dead Cedilla",
    140 to "Dead Ogonek",
    141 to "Dead Iota",
    142 to "Dead Voiced Sound",
    143 to "Dead Semivoiced Sound",
    144 to "Num Lock",
    145 to "Scroll Lock",
    150 to "Ampersand",
    151 to "Asterisk",
    152 to "Double Quote",
    153 to "Less",
    154 to "Print Screen",
    155 to "Insert",
    156 to "Help",
    157 to "Meta",
    160 to "Greater",
    161 to "Left Brace",
    162 to "Right Brace",
    192 to "Back Quote",
    222 to "Quote",
    224 to "Up",
    225 to "Down",
    226 to "Left",
    227 to "Right",
    240 to "Alphanumeric",
    241 to "Katakana",
    242 to "Hiragana",
    243 to "Full-Width",
    244 to "Half-Width",
    245 to "Roman Characters",
    256 to "All Candidates",
    257 to "Previous Candidate",
    258 to "Code Input",
    259 to "Japanese Katakana",
    260 to "Japanese Hiragana",
    261 to "Japanese Roman",
    262 to "Kana Lock",
    263 to "Input Method On/Off",
    512 to "At",
    513 to "Colon",
    514 to "Circumflex",
    515 to "Dollar",
    516 to "Euro",
    517 to "Exclamation Mark",
    518 to "Inverted Exclamation Mark",
    519 to "Left Parenthesis",
    520 to "Number Sign",
    521 to "Plus",
    522 to "Right Parenthesis",
    523 to "Underscore",
    524 to "Windows",
    525 to "Context Menu",
    61440 to "F13",
    61441 to "F14",
    61442 to "F15",
    61443 to "F16",
    61444 to "F17",
    61445 to "F18",
    61446 to "F19",
    61447 to "F20",
    61448 to "F21",
    61449 to "F22",
    61450 to "F23",
    61451 to "F24",
    65312 to "Compose",
    65368 to "Begin",
    65406 to "Alt Graph",
    65480 to "Stop",
    65481 to "Again",
    65482 to "Props",
    65483 to "Undo",
    65485 to "Copy",
    65487 to "Paste",
    65488 to "Find",
    65489 to "Cut",
)

/**
 * The texts macOS names keys by where they differ from the others': glyphs
 * for the modifier, editing and arrow keys, and the symbol keys by their
 * symbols, as the JDK's macOS toolkit resources name them.
 */
private val macKeyTexts: Map<Int, String> = mapOf(
    3 to "\u238b",
    8 to "\u232b",
    9 to "\u21e5",
    10 to "\u23ce",
    12 to "\u2327",
    16 to "\u21e7",
    17 to "\u2303",
    18 to "\u2325",
    20 to "\u21ea",
    27 to "\u238b",
    32 to "\u2423",
    33 to "\u21de",
    34 to "\u21df",
    35 to "\u2198",
    36 to "\u2196",
    37 to "\u2190",
    38 to "\u2191",
    39 to "\u2192",
    40 to "\u2193",
    44 to ",",
    45 to "-",
    46 to ".",
    47 to "/",
    59 to ";",
    61 to "=",
    91 to "[",
    92 to "\\",
    93 to "]",
    96 to "\u2328-0",
    97 to "\u2328-1",
    98 to "\u2328-2",
    99 to "\u2328-3",
    100 to "\u2328-4",
    101 to "\u2328-5",
    102 to "\u2328-6",
    103 to "\u2328-7",
    104 to "\u2328-8",
    105 to "\u2328-9",
    106 to "\u2328 *",
    107 to "\u2328 +",
    108 to "\u2328 ,",
    109 to "\u2328 -",
    110 to "\u2328 .",
    111 to "\u2328 /",
    127 to "\u2326",
    150 to "&",
    151 to "*",
    152 to "\"",
    153 to "<",
    154 to "\u2399",
    157 to "\u2318",
    160 to ">",
    161 to "[",
    162 to "]",
    192 to "`",
    222 to "'",
    224 to "\u2191",
    225 to "\u2193",
    226 to "\u2190",
    227 to "\u2192",
    512 to "@",
    513 to ":",
    514 to "^",
    515 to "\$",
    516 to "\u20ac",
    517 to "!",
    518 to "\u00a1",
    519 to "(",
    520 to "#",
    521 to "+",
    522 to ")",
    523 to "_",
    65406 to "\u2325",
)

internal fun __composeui_hostOs(): String = "unknown"

internal val isMacOs: Boolean by lazy { __composeui_hostOs() == "macos" }

/**
 * Whether the platform's key texts are in use. The desktop reads a key's text
 * from the AWT toolkit's resources, whose platform half loads with the
 * toolkit, which Compose Desktop starts with its first scene; before that a
 * key has the shared names. klio's scenes set this when the first one opens.
 */
internal var platformKeyTextsLoaded: Boolean = false

/** A key code's text: its name, or its code in hex for a key with none. */
private fun keyText(code: Int): String =
    (if (isMacOs && platformKeyTextsLoaded) macKeyTexts[code] else null)
        ?: keyTexts[code]
        ?: ("Unknown keyCode: 0x" + code.toString(16))
