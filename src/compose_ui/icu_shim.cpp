// Locale-aware date formatting over the ICU the Skia libraries bundle, with
// its data compiled in. The platform's date formatter answers the same
// questions from the same CLDR data: material3's PlatformDateFormat asks it
// for skeleton patterns, weekday names, the first day of the week and the
// hour cycle.
//
// The bundled ICU's C entry points carry a `_skiko` suffix and ship no
// headers, so the few used here are declared by hand from ICU's C API.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {
typedef char16_t UChar;
typedef int UErrorCode;
typedef double UDate;
typedef void UDateFormat;
typedef void UDateTimePatternGenerator;
typedef void UCalendar;

UDateFormat* udat_open_skiko(int timeStyle, int dateStyle, const char* locale, const UChar* tzID,
                             int32_t tzIDLength, const UChar* pattern, int32_t patternLength,
                             UErrorCode* status);
void udat_close_skiko(UDateFormat* format);
int32_t udat_format_skiko(const UDateFormat* format, UDate date, UChar* result, int32_t resultLength,
                          void* position, UErrorCode* status);
UDate udat_parse_skiko(const UDateFormat* format, const UChar* text, int32_t textLength,
                       int32_t* parsePos, UErrorCode* status);
void udat_setLenient_skiko(UDateFormat* fmt, bool isLenient);
int32_t udat_toPattern_skiko(const UDateFormat* fmt, bool localized, UChar* result, int32_t resultLength,
                             UErrorCode* status);
int32_t udat_getSymbols_skiko(const UDateFormat* fmt, int type, int32_t symbolIndex, UChar* result,
                              int32_t resultLength, UErrorCode* status);
UDateTimePatternGenerator* udatpg_open_skiko(const char* locale, UErrorCode* status);
void udatpg_close_skiko(UDateTimePatternGenerator* dtpg);
int32_t udatpg_getBestPattern_skiko(UDateTimePatternGenerator* dtpg, const UChar* skeleton, int32_t length,
                                    UChar* bestPattern, int32_t capacity, UErrorCode* status);
UCalendar* ucal_open_skiko(const UChar* zoneID, int32_t len, const char* locale, int type, UErrorCode* status);
int32_t ucal_getAttribute_skiko(const UCalendar* cal, int attr);
void ucal_close_skiko(UCalendar* cal);
int32_t uloc_forLanguageTag_skiko(const char* langtag, char* localeID, int32_t localeIDCapacity,
                                  int32_t* parsedLength, UErrorCode* err);
const char* uloc_getDefault_skiko(void);
UChar* u_strFromUTF8_skiko(UChar* dest, int32_t destCapacity, int32_t* pDestLength, const char* src,
                           int32_t srcLength, UErrorCode* pErrorCode);
char* u_strToUTF8_skiko(char* dest, int32_t destCapacity, int32_t* pDestLength, const UChar* src,
                        int32_t srcLength, UErrorCode* pErrorCode);
}

namespace {

constexpr int kUdatPattern = -2;
constexpr int kUdatNone = -1;
constexpr int kUdatShort = 3;
constexpr int kUdatStandaloneWeekdays = 13;
constexpr int kUdatStandaloneNarrowWeekdays = 15;
constexpr int kUcalGregorian = 1;
constexpr int kUcalFirstDayOfWeek = 1;

bool failed(UErrorCode status) { return status > 0; }

std::u16string toUtf16(const char* s) {
    if (!s) return {};
    UErrorCode status = 0;
    int32_t len = 0;
    u_strFromUTF8_skiko(nullptr, 0, &len, s, -1, &status);
    std::u16string out(static_cast<size_t>(len), u'\0');
    status = 0;
    u_strFromUTF8_skiko(out.data(), len, &len, s, -1, &status);
    if (failed(status)) return {};
    return out;
}

char* toUtf8Owned(const UChar* s, int32_t len) {
    UErrorCode status = 0;
    int32_t need = 0;
    u_strToUTF8_skiko(nullptr, 0, &need, s, len, &status);
    char* out = static_cast<char*>(std::malloc(static_cast<size_t>(need) + 1));
    if (!out) return nullptr;
    status = 0;
    u_strToUTF8_skiko(out, need + 1, &need, s, len, &status);
    if (failed(status)) {
        std::free(out);
        return nullptr;
    }
    out[need] = '\0';
    return out;
}

char* dupOwned(const std::string& s) {
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

// A BCP 47 tag ("en-GB") as an ICU locale id ("en_GB"); an empty tag is the
// root locale, which formats with invariant (POSIX-like) symbols.
std::string localeId(const char* tag) {
    if (!tag || !*tag) return "en_US_POSIX";
    char buf[157];
    UErrorCode status = 0;
    int32_t parsed = 0;
    const int32_t n = uloc_forLanguageTag_skiko(tag, buf, sizeof buf, &parsed, &status);
    if (failed(status) || n <= 0) return tag;
    return std::string(buf, static_cast<size_t>(n));
}

// Runs an ICU call that fills a UChar buffer, growing it once when the first
// guess is short, and returns the result as an owned UTF-8 string.
template <typename F>
char* fillUtf16(F&& call) {
    UChar small[256];
    UErrorCode status = 0;
    int32_t n = call(small, 256, &status);
    if (status == 15 /* U_BUFFER_OVERFLOW_ERROR */) {
        std::u16string big(static_cast<size_t>(n) + 1, u'\0');
        status = 0;
        n = call(big.data(), n + 1, &status);
        if (failed(status)) return nullptr;
        return toUtf8Owned(big.data(), n);
    }
    if (failed(status)) return nullptr;
    return toUtf8Owned(small, n);
}

UDateFormat* openPattern(const std::string& locale, const std::u16string& pattern) {
    static const std::u16string utc = u"UTC";
    UErrorCode status = 0;
    UDateFormat* f = udat_open_skiko(kUdatPattern, kUdatPattern, locale.c_str(), utc.data(),
                                     static_cast<int32_t>(utc.size()), pattern.data(),
                                     static_cast<int32_t>(pattern.size()), &status);
    if (failed(status)) {
        if (f) udat_close_skiko(f);
        return nullptr;
    }
    return f;
}

char* formatPattern(const char* tag, const char* pattern, double millis) {
    UDateFormat* f = openPattern(localeId(tag), toUtf16(pattern));
    if (!f) return nullptr;
    char* out = fillUtf16([&](UChar* buf, int32_t cap, UErrorCode* st) {
        return udat_format_skiko(f, millis, buf, cap, nullptr, st);
    });
    udat_close_skiko(f);
    return out;
}

char* bestPattern(const char* tag, const char* skeleton) {
    UErrorCode status = 0;
    UDateTimePatternGenerator* g = udatpg_open_skiko(localeId(tag).c_str(), &status);
    if (failed(status) || !g) return nullptr;
    const std::u16string sk = toUtf16(skeleton);
    char* out = fillUtf16([&](UChar* buf, int32_t cap, UErrorCode* st) {
        return udatpg_getBestPattern_skiko(g, sk.data(), static_cast<int32_t>(sk.size()), buf, cap, st);
    });
    udatpg_close_skiko(g);
    return out;
}

// The instant `text` names under `pattern`, strictly, as decimal
// milliseconds; null when it does not parse in full.
char* parsePattern(const char* tag, const char* pattern, const char* text) {
    UDateFormat* f = openPattern(localeId(tag), toUtf16(pattern));
    if (!f) return nullptr;
    udat_setLenient_skiko(f, false);
    const std::u16string t = toUtf16(text);
    int32_t pos = 0;
    UErrorCode status = 0;
    const UDate when = udat_parse_skiko(f, t.data(), static_cast<int32_t>(t.size()), &pos, &status);
    udat_close_skiko(f);
    if (failed(status) || pos != static_cast<int32_t>(t.size())) return nullptr;
    return dupOwned(std::to_string(static_cast<long long>(when)));
}

char* shortDatePattern(const char* tag) {
    UErrorCode status = 0;
    UDateFormat* f = udat_open_skiko(kUdatNone, kUdatShort, localeId(tag).c_str(), nullptr, -1, nullptr, -1,
                                     &status);
    if (failed(status) || !f) return nullptr;
    char* out = fillUtf16([&](UChar* buf, int32_t cap, UErrorCode* st) {
        return udat_toPattern_skiko(f, false, buf, cap, st);
    });
    udat_close_skiko(f);
    return out;
}

// The seven standalone weekday names from Sunday, each ending in '\n'.
char* weekdayNames(const char* tag, bool narrow) {
    UErrorCode status = 0;
    UDateFormat* f = udat_open_skiko(kUdatNone, kUdatShort, localeId(tag).c_str(), nullptr, -1, nullptr, -1,
                                     &status);
    if (failed(status) || !f) return nullptr;
    const int type = narrow ? kUdatStandaloneNarrowWeekdays : kUdatStandaloneWeekdays;
    std::string all;
    for (int day = 1; day <= 7; ++day) {
        char* name = fillUtf16([&](UChar* buf, int32_t cap, UErrorCode* st) {
            return udat_getSymbols_skiko(f, type, day, buf, cap, st);
        });
        if (!name) {
            udat_close_skiko(f);
            return nullptr;
        }
        all += name;
        all += '\n';
        std::free(name);
    }
    udat_close_skiko(f);
    return dupOwned(all);
}

// The first day of the week, 1 (Sunday) to 7 (Saturday).
char* firstDayOfWeek(const char* tag) {
    UErrorCode status = 0;
    UCalendar* c = ucal_open_skiko(nullptr, -1, localeId(tag).c_str(), kUcalGregorian, &status);
    if (failed(status) || !c) return nullptr;
    const int32_t day = ucal_getAttribute_skiko(c, kUcalFirstDayOfWeek);
    ucal_close_skiko(c);
    return dupOwned(std::to_string(day));
}

}  // namespace

extern "C" {

// One entry for the date questions: op 0 formats `millis` with pattern `a`,
// 1 is the best pattern for skeleton `a`, 2 parses `b` with pattern `a`,
// 3 is the short date pattern, 4 the weekday names (`a` "narrow" or "full"),
// 5 the first day of the week, 6 the default locale's tag. `tag` is a BCP 47
// language tag. The result is malloc'd (free with klio_skia_free_cstr), or
// null when ICU cannot answer.
char* klio_icu_date(int op, const char* tag, const char* a, const char* b, double millis) {
    switch (op) {
        case 0: return formatPattern(tag, a, millis);
        case 1: return bestPattern(tag, a);
        case 2: return parsePattern(tag, a, b);
        case 3: return shortDatePattern(tag);
        case 4: return weekdayNames(tag, a && std::strcmp(a, "narrow") == 0);
        case 5: return firstDayOfWeek(tag);
        case 6: return dupOwned(uloc_getDefault_skiko());
        default: return nullptr;
    }
}

}  // extern "C"
