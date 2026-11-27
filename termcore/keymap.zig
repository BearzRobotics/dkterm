// SPDX-License-Identifier: LGPL-2.0-or-later
//! Physical key mapping for the kitty keyboard protocol: Linux evdev codes to
//! the W3C-style key names libghostty-vt wants. GTK reports the evdev code + 8;
//! DKConsole reads evdev codes directly.

const std = @import("std");
const vt = @import("ghostty-vt");

const Key = vt.input.Key;

/// GTK/Wayland hardware keycode -> key, or `.unidentified`.
pub fn fromHardwareKeycode(keycode: u32) Key {
    if (keycode < 8) return .unidentified;
    return fromEvdev(keycode - 8);
}

/// Linux evdev key code (`KEY_*`) -> key, or `.unidentified`.
pub fn fromEvdev(code: u32) Key {
    return if (code < table.len) table[code] else .unidentified;
}

const table = blk: {
    var t: [256]Key = @splat(.unidentified);
    t[1] = .escape;
    const digits = [_]Key{ .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9, .digit_0 };
    for (digits, 0..) |k, i| t[2 + i] = k;
    t[12] = .minus;
    t[13] = .equal;
    t[14] = .backspace;
    t[15] = .tab;
    const row_q = [_]Key{ .key_q, .key_w, .key_e, .key_r, .key_t, .key_y, .key_u, .key_i, .key_o, .key_p };
    for (row_q, 0..) |k, i| t[16 + i] = k;
    t[26] = .bracket_left;
    t[27] = .bracket_right;
    t[28] = .enter;
    t[29] = .control_left;
    const row_a = [_]Key{ .key_a, .key_s, .key_d, .key_f, .key_g, .key_h, .key_j, .key_k, .key_l };
    for (row_a, 0..) |k, i| t[30 + i] = k;
    t[39] = .semicolon;
    t[40] = .quote;
    t[41] = .backquote;
    t[42] = .shift_left;
    t[43] = .backslash;
    const row_z = [_]Key{ .key_z, .key_x, .key_c, .key_v, .key_b, .key_n, .key_m };
    for (row_z, 0..) |k, i| t[44 + i] = k;
    t[51] = .comma;
    t[52] = .period;
    t[53] = .slash;
    t[54] = .shift_right;
    t[55] = .numpad_multiply;
    t[56] = .alt_left;
    t[57] = .space;
    t[58] = .caps_lock;
    const fkeys = [_]Key{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10 };
    for (fkeys, 0..) |k, i| t[59 + i] = k;
    t[69] = .num_lock;
    t[70] = .scroll_lock;
    t[71] = .numpad_7;
    t[72] = .numpad_8;
    t[73] = .numpad_9;
    t[74] = .numpad_subtract;
    t[75] = .numpad_4;
    t[76] = .numpad_5;
    t[77] = .numpad_6;
    t[78] = .numpad_add;
    t[79] = .numpad_1;
    t[80] = .numpad_2;
    t[81] = .numpad_3;
    t[82] = .numpad_0;
    t[83] = .numpad_decimal;
    t[86] = .intl_backslash;
    t[87] = .f11;
    t[88] = .f12;
    t[89] = .intl_ro;
    t[92] = .convert;
    t[93] = .kana_mode;
    t[94] = .non_convert;
    t[96] = .numpad_enter;
    t[97] = .control_right;
    t[98] = .numpad_divide;
    t[99] = .print_screen;
    t[100] = .alt_right;
    t[102] = .home;
    t[103] = .arrow_up;
    t[104] = .page_up;
    t[105] = .arrow_left;
    t[106] = .arrow_right;
    t[107] = .end;
    t[108] = .arrow_down;
    t[109] = .page_down;
    t[110] = .insert;
    t[111] = .delete;
    t[113] = .audio_volume_mute;
    t[114] = .audio_volume_down;
    t[115] = .audio_volume_up;
    t[116] = .power;
    t[117] = .numpad_equal;
    t[119] = .pause;
    t[121] = .numpad_comma;
    t[124] = .intl_yen;
    t[125] = .meta_left;
    t[126] = .meta_right;
    t[127] = .context_menu;
    t[128] = .browser_stop;
    t[133] = .copy;
    t[135] = .paste;
    t[137] = .cut;
    t[138] = .help;
    t[140] = .launch_app_2;
    t[142] = .sleep;
    t[143] = .wake_up;
    t[144] = .launch_app_1;
    t[155] = .launch_mail;
    t[156] = .browser_favorites;
    t[158] = .browser_back;
    t[159] = .browser_forward;
    t[161] = .eject;
    t[163] = .media_track_next;
    t[164] = .media_play_pause;
    t[165] = .media_track_previous;
    t[166] = .media_stop;
    t[171] = .media_select;
    t[172] = .browser_home;
    t[173] = .browser_refresh;
    t[179] = .numpad_paren_left;
    t[180] = .numpad_paren_right;
    t[217] = .browser_search;
    const more_fkeys = [_]Key{ .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 };
    for (more_fkeys, 0..) |k, i| t[183 + i] = k;
    break :blk t;
};

test "evdev codes map to physical keys" {
    // GTK keycode = evdev + 8.
    try std.testing.expectEqual(Key.key_a, fromHardwareKeycode(38));
    try std.testing.expectEqual(Key.enter, fromHardwareKeycode(36));
    try std.testing.expectEqual(Key.arrow_up, fromHardwareKeycode(111));
    try std.testing.expectEqual(Key.f1, fromHardwareKeycode(67));
    try std.testing.expectEqual(Key.escape, fromHardwareKeycode(9));
    try std.testing.expectEqual(Key.unidentified, fromHardwareKeycode(0));
    try std.testing.expectEqual(Key.unidentified, fromHardwareKeycode(5000));
}

/// Every code that has a key: the evdev numbers in the raw table of the
/// pinned ghostty (`src/input/keycodes.zig`, its XKB column less 8), for each
/// name in ghostty's `Key`.
const expected = [_]struct { u32, Key }{
    .{ 1, .escape },
    .{ 2, .digit_1 },
    .{ 3, .digit_2 },
    .{ 4, .digit_3 },
    .{ 5, .digit_4 },
    .{ 6, .digit_5 },
    .{ 7, .digit_6 },
    .{ 8, .digit_7 },
    .{ 9, .digit_8 },
    .{ 10, .digit_9 },
    .{ 11, .digit_0 },
    .{ 12, .minus },
    .{ 13, .equal },
    .{ 14, .backspace },
    .{ 15, .tab },
    .{ 16, .key_q },
    .{ 17, .key_w },
    .{ 18, .key_e },
    .{ 19, .key_r },
    .{ 20, .key_t },
    .{ 21, .key_y },
    .{ 22, .key_u },
    .{ 23, .key_i },
    .{ 24, .key_o },
    .{ 25, .key_p },
    .{ 26, .bracket_left },
    .{ 27, .bracket_right },
    .{ 28, .enter },
    .{ 29, .control_left },
    .{ 30, .key_a },
    .{ 31, .key_s },
    .{ 32, .key_d },
    .{ 33, .key_f },
    .{ 34, .key_g },
    .{ 35, .key_h },
    .{ 36, .key_j },
    .{ 37, .key_k },
    .{ 38, .key_l },
    .{ 39, .semicolon },
    .{ 40, .quote },
    .{ 41, .backquote },
    .{ 42, .shift_left },
    .{ 43, .backslash },
    .{ 44, .key_z },
    .{ 45, .key_x },
    .{ 46, .key_c },
    .{ 47, .key_v },
    .{ 48, .key_b },
    .{ 49, .key_n },
    .{ 50, .key_m },
    .{ 51, .comma },
    .{ 52, .period },
    .{ 53, .slash },
    .{ 54, .shift_right },
    .{ 55, .numpad_multiply },
    .{ 56, .alt_left },
    .{ 57, .space },
    .{ 58, .caps_lock },
    .{ 59, .f1 },
    .{ 60, .f2 },
    .{ 61, .f3 },
    .{ 62, .f4 },
    .{ 63, .f5 },
    .{ 64, .f6 },
    .{ 65, .f7 },
    .{ 66, .f8 },
    .{ 67, .f9 },
    .{ 68, .f10 },
    .{ 69, .num_lock },
    .{ 70, .scroll_lock },
    .{ 71, .numpad_7 },
    .{ 72, .numpad_8 },
    .{ 73, .numpad_9 },
    .{ 74, .numpad_subtract },
    .{ 75, .numpad_4 },
    .{ 76, .numpad_5 },
    .{ 77, .numpad_6 },
    .{ 78, .numpad_add },
    .{ 79, .numpad_1 },
    .{ 80, .numpad_2 },
    .{ 81, .numpad_3 },
    .{ 82, .numpad_0 },
    .{ 83, .numpad_decimal },
    .{ 86, .intl_backslash },
    .{ 87, .f11 },
    .{ 88, .f12 },
    .{ 89, .intl_ro },
    .{ 92, .convert },
    .{ 93, .kana_mode },
    .{ 94, .non_convert },
    .{ 96, .numpad_enter },
    .{ 97, .control_right },
    .{ 98, .numpad_divide },
    .{ 99, .print_screen },
    .{ 100, .alt_right },
    .{ 102, .home },
    .{ 103, .arrow_up },
    .{ 104, .page_up },
    .{ 105, .arrow_left },
    .{ 106, .arrow_right },
    .{ 107, .end },
    .{ 108, .arrow_down },
    .{ 109, .page_down },
    .{ 110, .insert },
    .{ 111, .delete },
    .{ 113, .audio_volume_mute },
    .{ 114, .audio_volume_down },
    .{ 115, .audio_volume_up },
    .{ 116, .power },
    .{ 117, .numpad_equal },
    .{ 119, .pause },
    .{ 121, .numpad_comma },
    .{ 124, .intl_yen },
    .{ 125, .meta_left },
    .{ 126, .meta_right },
    .{ 127, .context_menu },
    .{ 128, .browser_stop },
    .{ 133, .copy },
    .{ 135, .paste },
    .{ 137, .cut },
    .{ 138, .help },
    .{ 140, .launch_app_2 },
    .{ 142, .sleep },
    .{ 143, .wake_up },
    .{ 144, .launch_app_1 },
    .{ 155, .launch_mail },
    .{ 156, .browser_favorites },
    .{ 158, .browser_back },
    .{ 159, .browser_forward },
    .{ 161, .eject },
    .{ 163, .media_track_next },
    .{ 164, .media_play_pause },
    .{ 165, .media_track_previous },
    .{ 166, .media_stop },
    .{ 171, .media_select },
    .{ 172, .browser_home },
    .{ 173, .browser_refresh },
    .{ 179, .numpad_paren_left },
    .{ 180, .numpad_paren_right },
    .{ 183, .f13 },
    .{ 184, .f14 },
    .{ 185, .f15 },
    .{ 186, .f16 },
    .{ 187, .f17 },
    .{ 188, .f18 },
    .{ 189, .f19 },
    .{ 190, .f20 },
    .{ 191, .f21 },
    .{ 192, .f22 },
    .{ 193, .f23 },
    .{ 194, .f24 },
    .{ 217, .browser_search },
};

test "the whole table matches ghostty's key codes" {
    var want: [1024]Key = @splat(.unidentified);
    for (expected) |entry| want[entry[0]] = entry[1];
    for (want, 0..) |key, code| {
        std.testing.expectEqual(key, fromEvdev(@intCast(code))) catch |err| {
            std.debug.print("evdev code {d}\n", .{code});
            return err;
        };
    }
}
