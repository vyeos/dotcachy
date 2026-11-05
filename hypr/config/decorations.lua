-- Look and feel: Graphite. Flat, square, engraved, monochrome, matching the
-- Noctalia bar. Windows are solid squares with a 1px border: light grey on the
-- focused window (like the bar's active workspace mark), a near-invisible dark
-- groove on the rest. No rounding, shadows or forced translucency; blur stays
-- on for anything that is see-through (e.g. a translucent terminal). Unfocused
-- windows are dimmed a touch, so focus reads in grey alone.

hl.config({
    general = {
        gaps_in = 3,
        gaps_out = 6,
        border_size = 1,
        extend_border_grab_area = 10,
        resize_on_border = true,
        col = {
            active_border = G7,
            inactive_border = G3,
        },
    },
    group = {
        col = {
            border_active = G9,
            border_inactive = G4,
            border_locked_active = G7,
            border_locked_inactive = G4,
        },
        groupbar = {
            col = {
                active = G9,
                inactive = G4,
                locked_active = G7,
                locked_inactive = G4,
            },
        },
    },
    decoration = {
        rounding = 0,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        fullscreen_opacity = 1.0,
        dim_inactive = true,
        dim_strength = 0.12,
        dim_special = 0.4,
        shadow = {
            enabled = false,
        },
        blur = {
            enabled = true,
            size = 5,
            passes = 4,
            special = true,
        },
    },
})
