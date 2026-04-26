//! Unicode display width lookup based on Unicode 16.0.
//! Provides wcwidth-equivalent functionality for determining how many
//! terminal columns a character occupies.

const std = @import("std");

/// A Unicode codepoint range (inclusive).
const Range = struct {
    first: u21,
    last: u21,
};

/// Zero-width character ranges: combining marks (Mn/Me/Mc subset), format chars (Cf),
/// default ignorable code points, variation selectors, Hangul Jamo medials/finals, etc.
const zero_width_ranges = [_]Range{
    .{ .first = 0x00AD, .last = 0x00AD }, // SOFT HYPHEN
    .{ .first = 0x0300, .last = 0x036F }, // Combining Diacritical Marks
    .{ .first = 0x0483, .last = 0x0489 }, // Combining Cyrillic
    .{ .first = 0x0591, .last = 0x05BD }, // Hebrew combining
    .{ .first = 0x05BF, .last = 0x05BF },
    .{ .first = 0x05C1, .last = 0x05C2 },
    .{ .first = 0x05C4, .last = 0x05C5 },
    .{ .first = 0x05C7, .last = 0x05C7 },
    .{ .first = 0x0600, .last = 0x0605 }, // Arabic format
    .{ .first = 0x0610, .last = 0x061A }, // Arabic combining
    .{ .first = 0x061C, .last = 0x061C }, // Arabic Letter Mark
    .{ .first = 0x064B, .last = 0x065F }, // Arabic combining
    .{ .first = 0x0670, .last = 0x0670 },
    .{ .first = 0x06D6, .last = 0x06DD },
    .{ .first = 0x06DF, .last = 0x06E4 },
    .{ .first = 0x06E7, .last = 0x06E8 },
    .{ .first = 0x06EA, .last = 0x06ED },
    .{ .first = 0x070F, .last = 0x070F }, // Syriac Abbreviation Mark
    .{ .first = 0x0711, .last = 0x0711 }, // Syriac combining
    .{ .first = 0x0730, .last = 0x074A }, // Syriac combining
    .{ .first = 0x07A6, .last = 0x07B0 }, // Thaana combining
    .{ .first = 0x07EB, .last = 0x07F3 }, // NKo combining
    .{ .first = 0x07FD, .last = 0x07FD },
    .{ .first = 0x0816, .last = 0x0819 }, // Samaritan combining
    .{ .first = 0x081B, .last = 0x0823 },
    .{ .first = 0x0825, .last = 0x0827 },
    .{ .first = 0x0829, .last = 0x082D },
    .{ .first = 0x0859, .last = 0x085B }, // Mandaic combining
    .{ .first = 0x0890, .last = 0x0891 }, // Arabic format
    .{ .first = 0x0898, .last = 0x089F }, // Arabic combining
    .{ .first = 0x08CA, .last = 0x08E1 }, // Arabic combining
    .{ .first = 0x08E3, .last = 0x0902 }, // Arabic/Devanagari combining
    .{ .first = 0x093A, .last = 0x093A },
    .{ .first = 0x093C, .last = 0x093C },
    .{ .first = 0x0941, .last = 0x0948 },
    .{ .first = 0x094D, .last = 0x094D },
    .{ .first = 0x0951, .last = 0x0957 },
    .{ .first = 0x0962, .last = 0x0963 },
    .{ .first = 0x0981, .last = 0x0981 }, // Bengali
    .{ .first = 0x09BC, .last = 0x09BC },
    .{ .first = 0x09C1, .last = 0x09C4 },
    .{ .first = 0x09CD, .last = 0x09CD },
    .{ .first = 0x09E2, .last = 0x09E3 },
    .{ .first = 0x09FE, .last = 0x09FE },
    .{ .first = 0x0A01, .last = 0x0A02 }, // Gurmukhi
    .{ .first = 0x0A3C, .last = 0x0A3C },
    .{ .first = 0x0A41, .last = 0x0A42 },
    .{ .first = 0x0A47, .last = 0x0A48 },
    .{ .first = 0x0A4B, .last = 0x0A4D },
    .{ .first = 0x0A51, .last = 0x0A51 },
    .{ .first = 0x0A70, .last = 0x0A71 },
    .{ .first = 0x0A75, .last = 0x0A75 },
    .{ .first = 0x0A81, .last = 0x0A82 }, // Gujarati
    .{ .first = 0x0ABC, .last = 0x0ABC },
    .{ .first = 0x0AC1, .last = 0x0AC5 },
    .{ .first = 0x0AC7, .last = 0x0AC8 },
    .{ .first = 0x0ACD, .last = 0x0ACD },
    .{ .first = 0x0AE2, .last = 0x0AE3 },
    .{ .first = 0x0AFA, .last = 0x0AFF },
    .{ .first = 0x0B01, .last = 0x0B01 }, // Oriya
    .{ .first = 0x0B3C, .last = 0x0B3C },
    .{ .first = 0x0B3F, .last = 0x0B3F },
    .{ .first = 0x0B41, .last = 0x0B44 },
    .{ .first = 0x0B4D, .last = 0x0B4D },
    .{ .first = 0x0B55, .last = 0x0B56 },
    .{ .first = 0x0B62, .last = 0x0B63 },
    .{ .first = 0x0B82, .last = 0x0B82 }, // Tamil
    .{ .first = 0x0BC0, .last = 0x0BC0 },
    .{ .first = 0x0BCD, .last = 0x0BCD },
    .{ .first = 0x0C00, .last = 0x0C00 }, // Telugu
    .{ .first = 0x0C04, .last = 0x0C04 },
    .{ .first = 0x0C3C, .last = 0x0C3C },
    .{ .first = 0x0C3E, .last = 0x0C40 },
    .{ .first = 0x0C46, .last = 0x0C48 },
    .{ .first = 0x0C4A, .last = 0x0C4D },
    .{ .first = 0x0C55, .last = 0x0C56 },
    .{ .first = 0x0C62, .last = 0x0C63 },
    .{ .first = 0x0C81, .last = 0x0C81 }, // Kannada
    .{ .first = 0x0CBC, .last = 0x0CBC },
    .{ .first = 0x0CBF, .last = 0x0CBF },
    .{ .first = 0x0CC6, .last = 0x0CC6 },
    .{ .first = 0x0CCC, .last = 0x0CCD },
    .{ .first = 0x0CE2, .last = 0x0CE3 },
    .{ .first = 0x0D00, .last = 0x0D01 }, // Malayalam
    .{ .first = 0x0D3B, .last = 0x0D3C },
    .{ .first = 0x0D41, .last = 0x0D44 },
    .{ .first = 0x0D4D, .last = 0x0D4D },
    .{ .first = 0x0D62, .last = 0x0D63 },
    .{ .first = 0x0D81, .last = 0x0D81 }, // Sinhala
    .{ .first = 0x0DCA, .last = 0x0DCA },
    .{ .first = 0x0DD2, .last = 0x0DD4 },
    .{ .first = 0x0DD6, .last = 0x0DD6 },
    .{ .first = 0x0E31, .last = 0x0E31 }, // Thai
    .{ .first = 0x0E34, .last = 0x0E3A },
    .{ .first = 0x0E47, .last = 0x0E4E },
    .{ .first = 0x0EB1, .last = 0x0EB1 }, // Lao
    .{ .first = 0x0EB4, .last = 0x0EBC },
    .{ .first = 0x0EC8, .last = 0x0ECE },
    .{ .first = 0x0F18, .last = 0x0F19 }, // Tibetan
    .{ .first = 0x0F35, .last = 0x0F35 },
    .{ .first = 0x0F37, .last = 0x0F37 },
    .{ .first = 0x0F39, .last = 0x0F39 },
    .{ .first = 0x0F71, .last = 0x0F7E },
    .{ .first = 0x0F80, .last = 0x0F84 },
    .{ .first = 0x0F86, .last = 0x0F87 },
    .{ .first = 0x0F8D, .last = 0x0F97 },
    .{ .first = 0x0F99, .last = 0x0FBC },
    .{ .first = 0x0FC6, .last = 0x0FC6 },
    .{ .first = 0x102D, .last = 0x1030 }, // Myanmar
    .{ .first = 0x1032, .last = 0x1037 },
    .{ .first = 0x1039, .last = 0x103A },
    .{ .first = 0x103D, .last = 0x103E },
    .{ .first = 0x1058, .last = 0x1059 },
    .{ .first = 0x105E, .last = 0x1060 },
    .{ .first = 0x1071, .last = 0x1074 },
    .{ .first = 0x1082, .last = 0x1082 },
    .{ .first = 0x1085, .last = 0x1086 },
    .{ .first = 0x108D, .last = 0x108D },
    .{ .first = 0x109D, .last = 0x109D },
    .{ .first = 0x1160, .last = 0x11FF }, // Hangul Jamo medial vowels and final consonants
    .{ .first = 0x135D, .last = 0x135F }, // Ethiopic combining
    .{ .first = 0x1712, .last = 0x1714 }, // Tagalog
    .{ .first = 0x1732, .last = 0x1733 }, // Hanunoo
    .{ .first = 0x1752, .last = 0x1753 }, // Buhid
    .{ .first = 0x1772, .last = 0x1773 }, // Tagbanwa
    .{ .first = 0x17B4, .last = 0x17B5 }, // Khmer
    .{ .first = 0x17B7, .last = 0x17BD },
    .{ .first = 0x17C6, .last = 0x17C6 },
    .{ .first = 0x17C9, .last = 0x17D3 },
    .{ .first = 0x17DD, .last = 0x17DD },
    .{ .first = 0x180B, .last = 0x180F }, // Mongolian format/combining
    .{ .first = 0x1885, .last = 0x1886 }, // Mongolian combining
    .{ .first = 0x18A9, .last = 0x18A9 },
    .{ .first = 0x1920, .last = 0x1922 }, // Limbu
    .{ .first = 0x1927, .last = 0x1928 },
    .{ .first = 0x1932, .last = 0x1932 },
    .{ .first = 0x1939, .last = 0x193B },
    .{ .first = 0x1A17, .last = 0x1A18 }, // Buginese
    .{ .first = 0x1A1B, .last = 0x1A1B },
    .{ .first = 0x1A56, .last = 0x1A56 }, // Tai Tham
    .{ .first = 0x1A58, .last = 0x1A5E },
    .{ .first = 0x1A60, .last = 0x1A60 },
    .{ .first = 0x1A62, .last = 0x1A62 },
    .{ .first = 0x1A65, .last = 0x1A6C },
    .{ .first = 0x1A73, .last = 0x1A7C },
    .{ .first = 0x1A7F, .last = 0x1A7F },
    .{ .first = 0x1AB0, .last = 0x1ACE }, // Combining Diacritical Marks Extended
    .{ .first = 0x1B00, .last = 0x1B03 }, // Balinese
    .{ .first = 0x1B34, .last = 0x1B34 },
    .{ .first = 0x1B36, .last = 0x1B3A },
    .{ .first = 0x1B3C, .last = 0x1B3C },
    .{ .first = 0x1B42, .last = 0x1B42 },
    .{ .first = 0x1B6B, .last = 0x1B73 },
    .{ .first = 0x1B80, .last = 0x1B81 }, // Sundanese
    .{ .first = 0x1BA2, .last = 0x1BA5 },
    .{ .first = 0x1BA8, .last = 0x1BA9 },
    .{ .first = 0x1BAB, .last = 0x1BAD },
    .{ .first = 0x1BE6, .last = 0x1BE6 }, // Batak
    .{ .first = 0x1BE8, .last = 0x1BE9 },
    .{ .first = 0x1BED, .last = 0x1BED },
    .{ .first = 0x1BEF, .last = 0x1BF1 },
    .{ .first = 0x1C2C, .last = 0x1C33 }, // Lepcha
    .{ .first = 0x1C36, .last = 0x1C37 },
    .{ .first = 0x1CD0, .last = 0x1CD2 }, // Vedic Extensions
    .{ .first = 0x1CD4, .last = 0x1CE0 },
    .{ .first = 0x1CE2, .last = 0x1CE8 },
    .{ .first = 0x1CED, .last = 0x1CED },
    .{ .first = 0x1CF4, .last = 0x1CF4 },
    .{ .first = 0x1CF8, .last = 0x1CF9 },
    .{ .first = 0x1DC0, .last = 0x1DFF }, // Combining Diacritical Marks Supplement
    .{ .first = 0x200B, .last = 0x200F }, // Zero-width/format chars
    .{ .first = 0x202A, .last = 0x202E }, // Bidi format
    .{ .first = 0x2060, .last = 0x2064 }, // Invisible operators
    .{ .first = 0x2066, .last = 0x206F }, // Bidi format
    .{ .first = 0x20D0, .last = 0x20F0 }, // Combining Diacritical Marks for Symbols
    .{ .first = 0x2CEF, .last = 0x2CF1 }, // Coptic combining
    .{ .first = 0x2D7F, .last = 0x2D7F }, // Tifinagh combining
    .{ .first = 0x2DE0, .last = 0x2DFF }, // Cyrillic Extended-A combining
    .{ .first = 0x302A, .last = 0x302D }, // CJK ideographic tone marks
    .{ .first = 0x3099, .last = 0x309A }, // Japanese combining
    .{ .first = 0xA66F, .last = 0xA672 }, // Combining Cyrillic
    .{ .first = 0xA674, .last = 0xA67D },
    .{ .first = 0xA69E, .last = 0xA69F },
    .{ .first = 0xA6F0, .last = 0xA6F1 }, // Bamum combining
    .{ .first = 0xA802, .last = 0xA802 }, // Syloti Nagri
    .{ .first = 0xA806, .last = 0xA806 },
    .{ .first = 0xA80B, .last = 0xA80B },
    .{ .first = 0xA825, .last = 0xA826 },
    .{ .first = 0xA82C, .last = 0xA82C },
    .{ .first = 0xA8C4, .last = 0xA8C5 }, // Saurashtra
    .{ .first = 0xA8E0, .last = 0xA8F1 }, // Devanagari Extended combining
    .{ .first = 0xA8FF, .last = 0xA8FF },
    .{ .first = 0xA926, .last = 0xA92D }, // Kayah Li
    .{ .first = 0xA947, .last = 0xA951 }, // Rejang
    .{ .first = 0xA980, .last = 0xA982 }, // Javanese
    .{ .first = 0xA9B3, .last = 0xA9B3 },
    .{ .first = 0xA9B6, .last = 0xA9B9 },
    .{ .first = 0xA9BC, .last = 0xA9BD },
    .{ .first = 0xA9E5, .last = 0xA9E5 }, // Myanmar Extended-B
    .{ .first = 0xAA29, .last = 0xAA2E }, // Cham
    .{ .first = 0xAA31, .last = 0xAA32 },
    .{ .first = 0xAA35, .last = 0xAA36 },
    .{ .first = 0xAA43, .last = 0xAA43 },
    .{ .first = 0xAA4C, .last = 0xAA4C },
    .{ .first = 0xAA7C, .last = 0xAA7C },
    .{ .first = 0xAAB0, .last = 0xAAB0 }, // Tai Viet
    .{ .first = 0xAAB2, .last = 0xAAB4 },
    .{ .first = 0xAAB7, .last = 0xAAB8 },
    .{ .first = 0xAABE, .last = 0xAABF },
    .{ .first = 0xAAC1, .last = 0xAAC1 },
    .{ .first = 0xAAEC, .last = 0xAAED },
    .{ .first = 0xAAF6, .last = 0xAAF6 },
    .{ .first = 0xABE5, .last = 0xABE5 }, // Meetei Mayek
    .{ .first = 0xABE8, .last = 0xABE8 },
    .{ .first = 0xABED, .last = 0xABED },
    .{ .first = 0xFB1E, .last = 0xFB1E }, // Hebrew combining
    .{ .first = 0xFE00, .last = 0xFE0F }, // Variation Selectors
    .{ .first = 0xFE20, .last = 0xFE2F }, // Combining Half Marks
    .{ .first = 0xFEFF, .last = 0xFEFF }, // BOM / ZWNBSP
    .{ .first = 0xFFF9, .last = 0xFFFB }, // Interlinear annotation
    .{ .first = 0x101FD, .last = 0x101FD }, // Phaistos combining
    .{ .first = 0x102E0, .last = 0x102E0 }, // Coptic Epact combining
    .{ .first = 0x10376, .last = 0x1037A }, // Old Permic combining
    .{ .first = 0x10A01, .last = 0x10A03 }, // Kharoshthi combining
    .{ .first = 0x10A05, .last = 0x10A06 },
    .{ .first = 0x10A0C, .last = 0x10A0F },
    .{ .first = 0x10A38, .last = 0x10A3A },
    .{ .first = 0x10A3F, .last = 0x10A3F },
    .{ .first = 0x10AE5, .last = 0x10AE6 }, // Manichaean combining
    .{ .first = 0x10D24, .last = 0x10D27 }, // Hanifi Rohingya
    .{ .first = 0x10EAB, .last = 0x10EAC }, // Yezidi combining
    .{ .first = 0x10EFD, .last = 0x10EFF }, // Arabic Extended-C
    .{ .first = 0x10F46, .last = 0x10F50 }, // Sogdian combining
    .{ .first = 0x10F82, .last = 0x10F85 }, // Old Uyghur combining
    .{ .first = 0x11001, .last = 0x11001 }, // Brahmi
    .{ .first = 0x11038, .last = 0x11046 },
    .{ .first = 0x11070, .last = 0x11070 },
    .{ .first = 0x11073, .last = 0x11074 },
    .{ .first = 0x1107F, .last = 0x11081 }, // Kaithi
    .{ .first = 0x110B3, .last = 0x110B6 },
    .{ .first = 0x110B9, .last = 0x110BA },
    .{ .first = 0x110C2, .last = 0x110C2 },
    .{ .first = 0x11100, .last = 0x11102 }, // Chakma
    .{ .first = 0x11127, .last = 0x1112B },
    .{ .first = 0x1112D, .last = 0x11134 },
    .{ .first = 0x11173, .last = 0x11173 }, // Mahajani
    .{ .first = 0x11180, .last = 0x11181 }, // Sharada
    .{ .first = 0x111B6, .last = 0x111BE },
    .{ .first = 0x111C9, .last = 0x111CC },
    .{ .first = 0x111CF, .last = 0x111CF },
    .{ .first = 0x1122F, .last = 0x11231 }, // Khojki
    .{ .first = 0x11234, .last = 0x11234 },
    .{ .first = 0x11236, .last = 0x11237 },
    .{ .first = 0x1123E, .last = 0x1123E },
    .{ .first = 0x11241, .last = 0x11241 },
    .{ .first = 0x112DF, .last = 0x112DF }, // Khudawadi
    .{ .first = 0x112E3, .last = 0x112EA },
    .{ .first = 0x11300, .last = 0x11301 }, // Grantha
    .{ .first = 0x1133B, .last = 0x1133C },
    .{ .first = 0x11340, .last = 0x11340 },
    .{ .first = 0x11366, .last = 0x1136C },
    .{ .first = 0x11370, .last = 0x11374 },
    .{ .first = 0x11438, .last = 0x1143F }, // Newa
    .{ .first = 0x11442, .last = 0x11444 },
    .{ .first = 0x11446, .last = 0x11446 },
    .{ .first = 0x1145E, .last = 0x1145E },
    .{ .first = 0x114B3, .last = 0x114B8 }, // Tirhuta
    .{ .first = 0x114BA, .last = 0x114BA },
    .{ .first = 0x114BF, .last = 0x114C0 },
    .{ .first = 0x114C2, .last = 0x114C3 },
    .{ .first = 0x115B2, .last = 0x115B5 }, // Siddham
    .{ .first = 0x115BC, .last = 0x115BD },
    .{ .first = 0x115BF, .last = 0x115C0 },
    .{ .first = 0x115DC, .last = 0x115DD },
    .{ .first = 0x11633, .last = 0x1163A }, // Modi
    .{ .first = 0x1163D, .last = 0x1163D },
    .{ .first = 0x1163F, .last = 0x11640 },
    .{ .first = 0x116AB, .last = 0x116AB }, // Takri
    .{ .first = 0x116AD, .last = 0x116AD },
    .{ .first = 0x116B0, .last = 0x116B5 },
    .{ .first = 0x116B7, .last = 0x116B7 },
    .{ .first = 0x1171D, .last = 0x1171F }, // Ahom
    .{ .first = 0x11722, .last = 0x11725 },
    .{ .first = 0x11727, .last = 0x1172B },
    .{ .first = 0x1182F, .last = 0x11837 }, // Dogra
    .{ .first = 0x11839, .last = 0x1183A },
    .{ .first = 0x1193B, .last = 0x1193C }, // Dives Akuru
    .{ .first = 0x1193E, .last = 0x1193E },
    .{ .first = 0x11943, .last = 0x11943 },
    .{ .first = 0x119D4, .last = 0x119D7 }, // Nandinagari
    .{ .first = 0x119DA, .last = 0x119DB },
    .{ .first = 0x119E0, .last = 0x119E0 },
    .{ .first = 0x11A01, .last = 0x11A0A }, // Zanabazar Square
    .{ .first = 0x11A33, .last = 0x11A38 },
    .{ .first = 0x11A3B, .last = 0x11A3E },
    .{ .first = 0x11A47, .last = 0x11A47 },
    .{ .first = 0x11A51, .last = 0x11A56 }, // Soyombo
    .{ .first = 0x11A59, .last = 0x11A5B },
    .{ .first = 0x11A8A, .last = 0x11A96 },
    .{ .first = 0x11A98, .last = 0x11A99 },
    .{ .first = 0x11C30, .last = 0x11C36 }, // Bhaiksuki
    .{ .first = 0x11C38, .last = 0x11C3D },
    .{ .first = 0x11C3F, .last = 0x11C3F },
    .{ .first = 0x11C92, .last = 0x11CA7 }, // Marchen
    .{ .first = 0x11CAA, .last = 0x11CB0 },
    .{ .first = 0x11CB2, .last = 0x11CB3 },
    .{ .first = 0x11CB5, .last = 0x11CB6 },
    .{ .first = 0x11D31, .last = 0x11D36 }, // Masaram Gondi
    .{ .first = 0x11D3A, .last = 0x11D3A },
    .{ .first = 0x11D3C, .last = 0x11D3D },
    .{ .first = 0x11D3F, .last = 0x11D45 },
    .{ .first = 0x11D47, .last = 0x11D47 },
    .{ .first = 0x11D90, .last = 0x11D91 }, // Gunjala Gondi
    .{ .first = 0x11D95, .last = 0x11D95 },
    .{ .first = 0x11D97, .last = 0x11D97 },
    .{ .first = 0x11EF3, .last = 0x11EF4 }, // Makasar
    .{ .first = 0x11F00, .last = 0x11F01 }, // Siddham Extended
    .{ .first = 0x11F36, .last = 0x11F3A },
    .{ .first = 0x11F40, .last = 0x11F40 },
    .{ .first = 0x11F42, .last = 0x11F42 },
    .{ .first = 0x13430, .last = 0x13440 }, // Egyptian Hieroglyph format
    .{ .first = 0x13447, .last = 0x13455 },
    .{ .first = 0x16AF0, .last = 0x16AF4 }, // Bassa Vah combining
    .{ .first = 0x16B30, .last = 0x16B36 }, // Pahawh Hmong combining
    .{ .first = 0x16F4F, .last = 0x16F4F }, // Miao combining
    .{ .first = 0x16F8F, .last = 0x16F92 },
    .{ .first = 0x16FE4, .last = 0x16FE4 }, // Ideographic combining
    .{ .first = 0x1BC9D, .last = 0x1BC9E }, // Duployan combining
    .{ .first = 0x1BCA0, .last = 0x1BCA3 }, // Shorthand format
    .{ .first = 0x1CF00, .last = 0x1CF2D }, // Znamenny Musical combining
    .{ .first = 0x1CF30, .last = 0x1CF46 },
    .{ .first = 0x1D167, .last = 0x1D169 }, // Musical Symbols combining
    .{ .first = 0x1D173, .last = 0x1D182 },
    .{ .first = 0x1D185, .last = 0x1D18B },
    .{ .first = 0x1D1AA, .last = 0x1D1AD },
    .{ .first = 0x1D242, .last = 0x1D244 }, // Combining Greek Musical
    .{ .first = 0x1DA00, .last = 0x1DA36 }, // Signwriting combining
    .{ .first = 0x1DA3B, .last = 0x1DA6C },
    .{ .first = 0x1DA75, .last = 0x1DA75 },
    .{ .first = 0x1DA84, .last = 0x1DA84 },
    .{ .first = 0x1DA9B, .last = 0x1DA9F },
    .{ .first = 0x1DAA1, .last = 0x1DAAF },
    .{ .first = 0x1E000, .last = 0x1E006 }, // Glagolitic combining
    .{ .first = 0x1E008, .last = 0x1E018 },
    .{ .first = 0x1E01B, .last = 0x1E021 },
    .{ .first = 0x1E023, .last = 0x1E024 },
    .{ .first = 0x1E026, .last = 0x1E02A },
    .{ .first = 0x1E08F, .last = 0x1E08F }, // Cyrillic Extended-D
    .{ .first = 0x1E130, .last = 0x1E136 }, // Nyiakeng Puachue Hmong
    .{ .first = 0x1E2AE, .last = 0x1E2AE }, // Wancho combining
    .{ .first = 0x1E2EC, .last = 0x1E2EF }, // Mende Kikakui combining
    .{ .first = 0x1E4EC, .last = 0x1E4EF }, // Cypro-Minoan
    .{ .first = 0x1E8D0, .last = 0x1E8D6 }, // Mende Kikakui combining
    .{ .first = 0x1E944, .last = 0x1E94A }, // Adlam combining
    .{ .first = 0xE0001, .last = 0xE0001 }, // Language Tag
    .{ .first = 0xE0020, .last = 0xE007F }, // Tag characters
    .{ .first = 0xE0100, .last = 0xE01EF }, // Variation Selectors Supplement
};

/// Wide character ranges (2 cells): CJK, Hangul, fullwidth forms, emoji presentation, etc.
const wide_ranges = [_]Range{
    .{ .first = 0x1100, .last = 0x115F }, // Hangul Jamo initial consonants
    .{ .first = 0x231A, .last = 0x231B }, // Watch, Hourglass
    .{ .first = 0x2329, .last = 0x232A }, // Angle brackets
    .{ .first = 0x23E9, .last = 0x23EC }, // Double triangles
    .{ .first = 0x23F0, .last = 0x23F0 }, // Alarm clock
    .{ .first = 0x23F3, .last = 0x23F3 }, // Hourglass flowing
    .{ .first = 0x25FD, .last = 0x25FE }, // Medium small squares
    .{ .first = 0x2614, .last = 0x2615 }, // Umbrella, Hot beverage
    .{ .first = 0x2648, .last = 0x2653 }, // Zodiac signs
    .{ .first = 0x267F, .last = 0x267F }, // Wheelchair
    .{ .first = 0x2693, .last = 0x2693 }, // Anchor
    .{ .first = 0x26A1, .last = 0x26A1 }, // High voltage
    .{ .first = 0x26AA, .last = 0x26AB }, // Medium circles
    .{ .first = 0x26BD, .last = 0x26BE }, // Soccer, Baseball
    .{ .first = 0x26C4, .last = 0x26C5 }, // Snowman, Sun behind cloud
    .{ .first = 0x26CE, .last = 0x26CE }, // Ophiuchus
    .{ .first = 0x26D4, .last = 0x26D4 }, // No entry
    .{ .first = 0x26EA, .last = 0x26EA }, // Church
    .{ .first = 0x26F2, .last = 0x26F3 }, // Fountain, Golf
    .{ .first = 0x26F5, .last = 0x26F5 }, // Sailboat
    .{ .first = 0x26FA, .last = 0x26FA }, // Tent
    .{ .first = 0x26FD, .last = 0x26FD }, // Fuel pump
    .{ .first = 0x2702, .last = 0x2702 }, // Scissors
    .{ .first = 0x2705, .last = 0x2705 }, // Check mark
    .{ .first = 0x2708, .last = 0x270D }, // Airplane..Writing hand
    .{ .first = 0x270F, .last = 0x270F }, // Pencil
    .{ .first = 0x2712, .last = 0x2712 }, // Black nib
    .{ .first = 0x2714, .last = 0x2714 }, // Check mark
    .{ .first = 0x2716, .last = 0x2716 }, // Heavy multiplication
    .{ .first = 0x271D, .last = 0x271D }, // Latin cross
    .{ .first = 0x2721, .last = 0x2721 }, // Star of David
    .{ .first = 0x2728, .last = 0x2728 }, // Sparkles
    .{ .first = 0x2733, .last = 0x2734 }, // Eight spoked asterisk
    .{ .first = 0x2744, .last = 0x2744 }, // Snowflake
    .{ .first = 0x2747, .last = 0x2747 }, // Sparkle
    .{ .first = 0x274C, .last = 0x274C }, // Cross mark
    .{ .first = 0x274E, .last = 0x274E }, // Cross mark
    .{ .first = 0x2753, .last = 0x2755 }, // Question marks
    .{ .first = 0x2757, .last = 0x2757 }, // Exclamation mark
    .{ .first = 0x2763, .last = 0x2764 }, // Heart exclamation, Heart
    .{ .first = 0x2795, .last = 0x2797 }, // Plus, Minus, Division
    .{ .first = 0x27A1, .last = 0x27A1 }, // Right arrow
    .{ .first = 0x27B0, .last = 0x27B0 }, // Curly loop
    .{ .first = 0x27BF, .last = 0x27BF }, // Double curly loop
    .{ .first = 0x2934, .last = 0x2935 }, // Arrows
    .{ .first = 0x2B05, .last = 0x2B07 }, // Arrows
    .{ .first = 0x2B1B, .last = 0x2B1C }, // Large squares
    .{ .first = 0x2B50, .last = 0x2B50 }, // Star
    .{ .first = 0x2B55, .last = 0x2B55 }, // Large circle
    .{ .first = 0x2E80, .last = 0x2E99 }, // CJK Radicals Supplement
    .{ .first = 0x2E9B, .last = 0x2EF3 },
    .{ .first = 0x2F00, .last = 0x2FD5 }, // Kangxi Radicals
    .{ .first = 0x2FF0, .last = 0x303E }, // Ideographic Description + CJK Symbols
    .{ .first = 0x3041, .last = 0x3096 }, // Hiragana
    .{ .first = 0x3099, .last = 0x30FF }, // Hiragana/Katakana
    .{ .first = 0x3105, .last = 0x312F }, // Bopomofo
    .{ .first = 0x3131, .last = 0x318E }, // Hangul Compatibility Jamo
    .{ .first = 0x3190, .last = 0x31E3 }, // Kanbun + CJK Strokes
    .{ .first = 0x31EF, .last = 0x321E }, // CJK Ideographic Telegraph + Enclosed CJK
    .{ .first = 0x3220, .last = 0x3247 },
    .{ .first = 0x3250, .last = 0x4DBF }, // Enclosed CJK + CJK Unified Ext A
    .{ .first = 0x4E00, .last = 0xA48C }, // CJK Unified Ideographs + Yi Syllables
    .{ .first = 0xA490, .last = 0xA4C6 }, // Yi Radicals
    .{ .first = 0xA960, .last = 0xA97C }, // Hangul Jamo Extended-A
    .{ .first = 0xAC00, .last = 0xD7A3 }, // Hangul Syllables
    .{ .first = 0xF900, .last = 0xFAFF }, // CJK Compatibility Ideographs
    .{ .first = 0xFE10, .last = 0xFE19 }, // Vertical Forms
    .{ .first = 0xFE30, .last = 0xFE6B }, // CJK Compatibility Forms + Small Form Variants
    .{ .first = 0xFF01, .last = 0xFF60 }, // Fullwidth ASCII + Fullwidth punctuation
    .{ .first = 0xFFE0, .last = 0xFFE6 }, // Fullwidth signs
    .{ .first = 0x16FE0, .last = 0x16FE4 }, // Ideographic Symbols
    .{ .first = 0x16FF0, .last = 0x16FF1 },
    .{ .first = 0x17000, .last = 0x187F7 }, // Tangut
    .{ .first = 0x18800, .last = 0x18CD5 }, // Tangut Components
    .{ .first = 0x18D00, .last = 0x18D08 }, // Tangut Supplement
    .{ .first = 0x1AFF0, .last = 0x1AFF3 }, // Kana Extended-B
    .{ .first = 0x1AFF5, .last = 0x1AFFB },
    .{ .first = 0x1AFFD, .last = 0x1AFFE },
    .{ .first = 0x1B000, .last = 0x1B122 }, // Kana Supplement + Kana Extended-A
    .{ .first = 0x1B132, .last = 0x1B132 },
    .{ .first = 0x1B150, .last = 0x1B152 }, // Small Kana Extension
    .{ .first = 0x1B155, .last = 0x1B155 },
    .{ .first = 0x1B164, .last = 0x1B167 },
    .{ .first = 0x1B170, .last = 0x1B2FB }, // Nushu
    .{ .first = 0x1F004, .last = 0x1F004 }, // Mahjong tile
    .{ .first = 0x1F0CF, .last = 0x1F0CF }, // Playing card
    .{ .first = 0x1F18E, .last = 0x1F18E }, // AB button
    .{ .first = 0x1F191, .last = 0x1F19A }, // Squared symbols
    .{ .first = 0x1F1E0, .last = 0x1F1FF }, // Regional Indicators (flags)
    .{ .first = 0x1F200, .last = 0x1F202 }, // Enclosed Ideographic Supplement
    .{ .first = 0x1F210, .last = 0x1F23B },
    .{ .first = 0x1F240, .last = 0x1F248 },
    .{ .first = 0x1F250, .last = 0x1F251 },
    .{ .first = 0x1F260, .last = 0x1F265 },
    .{ .first = 0x1F300, .last = 0x1F320 }, // Miscellaneous Symbols and Pictographs
    .{ .first = 0x1F32D, .last = 0x1F335 },
    .{ .first = 0x1F337, .last = 0x1F37C },
    .{ .first = 0x1F37E, .last = 0x1F393 },
    .{ .first = 0x1F3A0, .last = 0x1F3CA },
    .{ .first = 0x1F3CF, .last = 0x1F3D3 },
    .{ .first = 0x1F3E0, .last = 0x1F3F0 },
    .{ .first = 0x1F3F4, .last = 0x1F3F4 },
    .{ .first = 0x1F3F8, .last = 0x1F43E },
    .{ .first = 0x1F440, .last = 0x1F440 },
    .{ .first = 0x1F442, .last = 0x1F4FC },
    .{ .first = 0x1F4FF, .last = 0x1F53D },
    .{ .first = 0x1F54B, .last = 0x1F54E },
    .{ .first = 0x1F550, .last = 0x1F567 },
    .{ .first = 0x1F57A, .last = 0x1F57A },
    .{ .first = 0x1F595, .last = 0x1F596 },
    .{ .first = 0x1F5A4, .last = 0x1F5A4 },
    .{ .first = 0x1F5FB, .last = 0x1F64F },
    .{ .first = 0x1F680, .last = 0x1F6C5 },
    .{ .first = 0x1F6CC, .last = 0x1F6CC },
    .{ .first = 0x1F6D0, .last = 0x1F6D2 },
    .{ .first = 0x1F6D5, .last = 0x1F6D7 },
    .{ .first = 0x1F6DC, .last = 0x1F6DF },
    .{ .first = 0x1F6EB, .last = 0x1F6EC },
    .{ .first = 0x1F6F4, .last = 0x1F6FC },
    .{ .first = 0x1F7E0, .last = 0x1F7EB },
    .{ .first = 0x1F7F0, .last = 0x1F7F0 },
    .{ .first = 0x1F90C, .last = 0x1F93A },
    .{ .first = 0x1F93C, .last = 0x1F945 },
    .{ .first = 0x1F947, .last = 0x1F9FF },
    .{ .first = 0x1FA70, .last = 0x1FA7C },
    .{ .first = 0x1FA80, .last = 0x1FA89 },
    .{ .first = 0x1FA8F, .last = 0x1FAC6 },
    .{ .first = 0x1FACE, .last = 0x1FADC },
    .{ .first = 0x1FADF, .last = 0x1FAE9 },
    .{ .first = 0x1FAF0, .last = 0x1FAF8 },
    .{ .first = 0x20000, .last = 0x2FFFD }, // CJK Unified Ideographs Extension B-F + Supplementary
    .{ .first = 0x30000, .last = 0x3FFFD }, // CJK Unified Ideographs Extension G-I + Tertiary
};

/// Binary search for a codepoint within sorted range tables.
fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp > ranges[mid].last) {
            lo = mid + 1;
        } else if (cp < ranges[mid].first) {
            hi = mid;
        } else {
            return true;
        }
    }
    return false;
}

/// Returns the display width of a Unicode codepoint.
/// -1 = non-printable control, 0 = zero-width, 1 = normal, 2 = wide (double-width).
pub fn codepointWidth(cp: u21) i3 {
    // C0 controls (except HT, LF which callers handle)
    if (cp < 0x20) return -1;
    // DEL
    if (cp == 0x7F) return -1;
    // C1 controls
    if (cp >= 0x80 and cp <= 0x9F) return -1;

    // Zero-width
    if (inRanges(cp, &zero_width_ranges)) return 0;

    // Wide
    if (inRanges(cp, &wide_ranges)) return 2;

    // Private Use Areas — treat as width 1
    // Noncharacters — treat as width 1

    return 1;
}

/// Convenience wrapper: returns display width clamped to 0 (controls treated as 0).
pub fn charWidth(cp: u21) usize {
    const w = codepointWidth(cp);
    return if (w > 0) @intCast(w) else 0;
}

/// Calculate the display width of a UTF-8 string (no ANSI awareness).
pub fn strWidth(str: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(str[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > str.len) break;
        const cp = std.unicode.utf8Decode(str[i..][0..byte_len]) catch {
            i += 1;
            continue;
        };
        w += charWidth(cp);
        i += byte_len;
    }
    return w;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "ASCII characters are width 1" {
    try std.testing.expectEqual(@as(usize, 1), charWidth('A'));
    try std.testing.expectEqual(@as(usize, 1), charWidth('z'));
    try std.testing.expectEqual(@as(usize, 1), charWidth(' '));
    try std.testing.expectEqual(@as(usize, 1), charWidth('~'));
}

test "control characters are width 0 via charWidth" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x00)); // NUL
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x01)); // SOH
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x7F)); // DEL
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x80)); // C1
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x9F)); // C1 end
}

test "control characters are -1 via codepointWidth" {
    try std.testing.expectEqual(@as(i3, -1), codepointWidth(0x00));
    try std.testing.expectEqual(@as(i3, -1), codepointWidth(0x7F));
    try std.testing.expectEqual(@as(i3, -1), codepointWidth(0x9F));
}

test "combining marks are zero-width" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x0300)); // Combining Grave Accent
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x0301)); // Combining Acute Accent
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x036F)); // End of basic combining
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x20D0)); // Combining symbol marks
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xFE0F)); // Variation Selector-16
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xFE00)); // Variation Selector-1
}

test "zero-width format characters" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x200B)); // ZWSP
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x200C)); // ZWNJ
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xFEFF)); // BOM
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x2060)); // Word Joiner
}

test "CJK ideographs are wide" {
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x4E00)); // CJK Unified start
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x9FFF)); // CJK Unified
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x4E2D)); // 中
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x6587)); // 文
}

test "Hangul syllables are wide" {
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xAC00)); // Hangul Syllable start
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xD7A3)); // Hangul Syllable end
}

test "Hangul Jamo medials/finals are zero-width" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x1160)); // Jamo medial start
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x11FF)); // Jamo final end
}

test "fullwidth forms are wide" {
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xFF01)); // Fullwidth !
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xFF21)); // Fullwidth A
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xFF41)); // Fullwidth a
}

test "halfwidth Katakana is normal width" {
    try std.testing.expectEqual(@as(usize, 1), charWidth(0xFF61)); // Halfwidth Katakana start
    try std.testing.expectEqual(@as(usize, 1), charWidth(0xFF9F)); // Halfwidth Katakana end
}

test "emoji are wide" {
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x1F600)); // Grinning face
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x1F4A9)); // Pile of poo
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x1F680)); // Rocket
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x2615));  // Hot beverage
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x231A));  // Watch
}

test "variation selectors are zero-width" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xE0100)); // VS17
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xE01EF)); // VS256
}

test "strWidth with mixed content" {
    try std.testing.expectEqual(@as(usize, 4), strWidth("中文")); // 2 wide chars
    try std.testing.expectEqual(@as(usize, 5), strWidth("hello"));
    try std.testing.expectEqual(@as(usize, 6), strWidth("hi中文")); // h=1 i=1 中=2 文=2 => 6
}

test "strWidth with combining characters" {
    // e + combining acute accent = 1 display column
    try std.testing.expectEqual(@as(usize, 1), strWidth("e\xcc\x81"));
    // a + combining ring above = 1
    try std.testing.expectEqual(@as(usize, 1), strWidth("a\xcc\x8a"));
}

test "CJK Extension B is wide" {
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x20000)); // Extension B start
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x2A6DF)); // Extension B range
}

test "soft hyphen is zero-width" {
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x00AD));
}
