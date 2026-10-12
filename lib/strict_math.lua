-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek
--
-- sin, cos, atan and atan2 are ported from FreeBSD msun as shipped in musl
-- libc (k_sin.c, k_cos.c, e_rem_pio2.c, s_atan.c, e_atan2.c):
--
--   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
--
--   Developed at SunSoft, a Sun Microsystems, Inc. business.
--   Permission to use, copy, modify, and distribute this
--   software is freely granted, provided that this notice
--   is preserved.

-- Trigonometry that returns the same bits on every platform.
--
-- math.sin and its relatives come from the platform's C library, and every C
-- library rounds the last bit its own way. IEEE 754 only fixes the result of
-- + - * / and sqrt, so everything here is built from those alone, in a fixed
-- order. A lockstep simulation or a replay that has to reproduce on another
-- machine takes its angles from here instead of from math.
--
-- The contract:
--   - One result per input wherever numbers are IEEE doubles rounded to
--     nearest and a multiply is never fused with an add: PUC Lua 5.1 to 5.4,
--     and LuaJIT in the interpreter and its x86 / x64 JIT. LuaJIT's arm64 JIT
--     qualifies as long as -O+fma stays off, which is its default.
--   - sin and cos equal musl's bit for bit for |x| < 2^20 * pi/2. Beyond that
--     the argument is first reduced modulo 2 pi in double arithmetic, which is
--     still deterministic but loses accuracy as |x| grows.
--   - atan equals musl's. atan2 does too, except where |y / x| is within a
--     factor of two of 2^64 or 2^-64, where the last bit may differ.
--   - deg and rad are PUC Lua's: x / (pi / 180) and x * (pi / 180). LuaJIT's
--     math.deg multiplies by 180 / pi and differs in the last bit.
--
-- No dependencies, no globals, plain Lua 5.1 syntax. The constants are written
-- as an integer mantissa and a power of two, so they do not depend on how the
-- host converts a decimal literal either.
local StrictMath = {}

local abs, floor, huge = math.abs, math.floor, math.huge

-- mantissa * 2^exponent, exact.
local function scaled(mantissa, exponent)
    local step = exponent < 0 and 0.5 or 2.0
    for _ = 1, abs(exponent) do mantissa = mantissa * step end
    return mantissa
end

local PI          = scaled(884279719003555, -48)     -- 3.14159265358979323846
local PI_LO       = scaled(4967757600021511, -105)   -- 1.2246467991473531772e-16
local PIO2        = PI * 0.5
local PIO4        = PI * 0.25
local THREE_PIO4  = 3 * PI / 4
local TWO_PI      = 2 * PI
local RAD_PER_DEG = PI / 180
local NEG_ZERO    = -1 / huge

-- sin kernel
local S1 = scaled(-6004799503160649, -55)   -- -1.66666666666666324348e-01
local S2 = scaled(2401919801261139, -58)    --  8.33333333332248946124e-03
local S3 = scaled(-7320136532976085, -65)   -- -1.98412698298579493134e-04
local S4 = scaled(6506786730409597, -71)    --  2.75573137070700676789e-06
local S5 = scaled(-7571127717829867, -78)   -- -2.50507602534068634195e-08
local S6 = scaled(1537454791456095, -83)    --  1.58969099521155010221e-10

-- cos kernel
local C1 = scaled(1501199875790163, -55)    --  4.16666666666666019037e-02
local C2 = scaled(-6405119470031223, -62)   -- -1.38888888888741095749e-03
local C3 = scaled(457508533350745, -64)     --  2.48015872894767294178e-05
local C4 = scaled(-5205429506036397, -74)   -- -2.75573143513906633035e-07
local C5 = scaled(1261860039765105, -79)    --  2.08757232129817482790e-09
local C6 = scaled(-1757820317994549, -87)   -- -1.13596475577881948265e-11

-- pi/2 in three 33 bit pieces, each with the tail that follows it
local INVPIO2 = scaled(5734161139222659, -53)    -- 6.36619772367581382433e-01
local PIO2_1  = scaled(1686629713, -30)          -- 1.57079632673412561417e+00
local PIO2_1T = scaled(4701928774853425, -86)    -- 6.07710050650619224932e-11
local PIO2_2  = scaled(2242054355, -65)          -- 6.07710050630396597660e-11
local PIO2_2T = scaled(5376105825661043, -121)   -- 2.02226624879595063154e-21
local PIO2_3  = scaled(160220439, -96)           -- 2.02226624871116645580e-21
local PIO2_3T = scaled(7744522442262977, -156)   -- 8.47842766036889956997e-32
local TOINT   = scaled(3, 51)                    -- 1.5 / DBL_EPSILON

-- msun branches on the high 32 bits of |x|. Each bound here is the first
-- double whose high word is past the one msun compares with, so a plain
-- comparison takes the same branch.
local TINY_SIN       = scaled(1, -26)
local TINY_COS       = scaled(741455, -46)
local BOUND_PIO4     = scaled(411775, -19)
local BOUND_3PIO4    = scaled(1235325, -19)
local BOUND_5PIO4    = scaled(2058875, -19)
local BOUND_7PIO4    = scaled(1441213, -18)
local BOUND_9PIO4    = scaled(463247, -16)
local BOUND_MEDIUM   = 1647099
local NEAR_PIO2      = scaled(1647099, -20)
local NEAR_PIO2_END  = scaled(411775, -18)
local NEAR_PI        = scaled(1647099, -19)
local NEAR_PI_END    = scaled(411775, -17)
local NEAR_3PIO2     = scaled(308831, -16)
local NEAR_3PIO2_END = scaled(1235325, -18)
local NEAR_2PI       = scaled(1647099, -18)
local NEAR_2PI_END   = scaled(411775, -16)
local TWO_16         = scaled(1, 16)
local TWO_49         = scaled(1, 49)
local TWO_64         = scaled(1, 64)
local TWO_M64        = scaled(1, -64)
local TWO_66         = scaled(1, 66)
local TWO_M27        = scaled(1, -27)

-- atan(0.5), atan(1), atan(1.5), atan(inf), each as a high and a low part
local ATAN_HI = {
    scaled(8352332796509007, -54),   -- 4.63647609000806093515e-01
    scaled(884279719003555, -50),    -- 7.85398163397448278999e-01
    scaled(8852218891597467, -53),   -- 9.82793723247329054082e-01
    scaled(884279719003555, -49),    -- 1.57079632679489655800e+00
}
local ATAN_LO = {
    scaled(3683087214424817, -107),  -- 2.26987774529616870924e-17
    scaled(4967757600021511, -107),  -- 3.06161699786838301793e-17
    scaled(4511882386918333, -108),  -- 1.39033110312309984516e-17
    scaled(4967757600021511, -106),  -- 6.12323399573676603587e-17
}

-- atan polynomial
local T0  = scaled(6004799503160589, -54)    --  3.33333333333329318027e-01
local T1  = scaled(-1801439850937073, -53)   -- -1.99999999998764832476e-01
local T2  = scaled(5146970997949439, -55)    --  1.42857142725034663711e-01
local T3  = scaled(-8006398829074033, -56)   -- -1.11111104054623557880e-01
local T4  = scaled(3275337272528951, -55)    --  9.09088713343650656196e-02
local T5  = scaled(-5542580929731181, -56)   -- -7.69187620504482999495e-02
local T6  = scaled(4799809039908177, -56)    --  6.66107313738753120669e-02
local T7  = scaled(-4203530284924621, -56)   -- -5.83357013379057348645e-02
local T8  = scaled(7172437082246635, -57)    --  4.97687799461593236017e-02
local T9  = scaled(-5264754476739631, -57)   -- -3.65315727442169155270e-02
local T10 = scaled(4694068057790993, -58)    --  1.62858201153657823623e-02

-- sin(x + y) for |x| <= pi/4, y the tail of x. tail is false when y is 0.
local function kernel_sin(x, y, tail)
    local z = x * x
    local w = z * z
    local r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6)
    local v = z * x
    if not tail then return x + v * (S1 + z * r) end
    return x - ((z * (0.5 * y - v * r) - y) - v * S1)
end

-- cos(x + y) for |x| <= pi/4, y the tail of x.
local function kernel_cos(x, y)
    local z  = x * x
    local w  = z * z
    local r  = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6))
    local hz = 0.5 * z
    w = 1.0 - hz
    return w + (((1.0 - w) - hz) + (z * r - x * y))
end

-- x minus the nearest multiple n of pi/2, as n and the remainder in two parts.
-- Takes more of pi/2 when the remainder has cancelled against x.
local function reduce_medium(x, ax)
    local fn = x * INVPIO2 + TOINT - TOINT
    local r  = x - fn * PIO2_1
    local w  = fn * PIO2_1T
    local y0 = r - w
    local scale = 0.5   -- the power of two at or below |x|
    while scale + scale <= ax do scale = scale + scale end
    if abs(y0) * TWO_16 < scale then
        local t = r
        w  = fn * PIO2_2
        r  = t - w
        w  = fn * PIO2_2T - ((t - r) - w)
        y0 = r - w
        if abs(y0) * TWO_49 < scale then
            t  = r
            w  = fn * PIO2_3
            r  = t - w
            w  = fn * PIO2_3T - ((t - r) - w)
            y0 = r - w
        end
    end
    return fn, y0, (r - y0) - w
end

-- The same for an x known to lie about k * pi/2 from zero.
local function reduce_near(x, k)
    local head, tail = k * PIO2_1, k * PIO2_1T
    if x > 0 then
        local z  = x - head
        local y0 = z - tail
        return k, y0, (z - y0) - tail
    end
    local z  = x + head
    local y0 = z + tail
    return -k, y0, (z - y0) + tail
end

-- pi/4 < |x| < BOUND_MEDIUM
local function reduce(x, ax)
    if ax < BOUND_5PIO4 then
        if (ax >= NEAR_PIO2 and ax < NEAR_PIO2_END) or (ax >= NEAR_PI and ax < NEAR_PI_END) then
            return reduce_medium(x, ax)
        end
        return reduce_near(x, ax < BOUND_3PIO4 and 1 or 2)
    end
    if ax < BOUND_9PIO4 then
        if ax < BOUND_7PIO4 then
            if ax >= NEAR_3PIO2 and ax < NEAR_3PIO2_END then return reduce_medium(x, ax) end
            return reduce_near(x, 3)
        end
        if ax >= NEAR_2PI and ax < NEAR_2PI_END then return reduce_medium(x, ax) end
        return reduce_near(x, 4)
    end
    return reduce_medium(x, ax)
end

local function sin(x)
    local ax = abs(x)
    if ax < BOUND_PIO4 then
        if ax < TINY_SIN then return x end
        return kernel_sin(x, 0, false)
    end
    if ax == huge or ax ~= ax then return x - x end
    if ax >= BOUND_MEDIUM then return sin(x - floor(x / TWO_PI) * TWO_PI) end
    local n, y0, y1 = reduce(x, ax)
    n = n % 4
    if n == 0 then return kernel_sin(y0, y1, true) end
    if n == 1 then return kernel_cos(y0, y1) end
    if n == 2 then return -kernel_sin(y0, y1, true) end
    return -kernel_cos(y0, y1)
end

local function cos(x)
    local ax = abs(x)
    if ax < BOUND_PIO4 then
        if ax < TINY_COS then return 1.0 end
        return kernel_cos(x, 0)
    end
    if ax == huge or ax ~= ax then return x - x end
    if ax >= BOUND_MEDIUM then return cos(x - floor(x / TWO_PI) * TWO_PI) end
    local n, y0, y1 = reduce(x, ax)
    n = n % 4
    if n == 0 then return kernel_cos(y0, y1) end
    if n == 1 then return -kernel_sin(y0, y1, true) end
    if n == 2 then return -kernel_cos(y0, y1) end
    return kernel_sin(y0, y1, true)
end

local function atan(x)
    if x ~= x then return x end
    local ax = abs(x)
    if ax >= TWO_66 then return x < 0 and -ATAN_HI[4] or ATAN_HI[4] end
    local id
    if ax < 0.4375 then
        if ax < TWO_M27 then return x end
    elseif ax < 1.1875 then
        if ax < 0.6875 then
            id, ax = 1, (2.0 * ax - 1.0) / (2.0 + ax)
        else
            id, ax = 2, (ax - 1.0) / (ax + 1.0)
        end
    elseif ax < 2.4375 then
        id, ax = 3, (ax - 1.5) / (1.0 + 1.5 * ax)
    else
        id, ax = 4, -1.0 / ax
    end
    local t  = id and ax or x
    local z  = t * t
    local w  = z * z
    local s1 = z * (T0 + w * (T2 + w * (T4 + w * (T6 + w * (T8 + w * T10)))))
    local s2 = w * (T1 + w * (T3 + w * (T5 + w * (T7 + w * T9))))
    if not id then return t - t * (s1 + s2) end
    z = ATAN_HI[id] - (t * (s1 + s2) - ATAN_LO[id] - t)
    if x < 0 then return -z end
    return z
end

local function atan2(y, x)
    if x ~= x or y ~= y then return x + y end
    if x == 1 then return atan(y) end
    local x_neg = x < 0 or (x == 0 and 1 / x < 0)
    local y_neg = y < 0 or (y == 0 and 1 / y < 0)
    if y == 0 then
        if not x_neg then return y end
        return y_neg and -PI or PI
    end
    if x == 0 then return y_neg and -PIO2 or PIO2 end
    local ax, ay = abs(x), abs(y)
    if ax == huge then
        if ay == huge then
            local diagonal = x_neg and THREE_PIO4 or PIO4
            return y_neg and -diagonal or diagonal
        end
        if x_neg then return y_neg and -PI or PI end
        if y_neg then return NEG_ZERO end
        return 0
    end
    local ratio = ay / ax
    if ay == huge or ratio > TWO_64 then return y_neg and -PIO2 or PIO2 end
    local z = 0
    if not (x_neg and ratio < TWO_M64) then z = atan(ratio) end
    if not x_neg then return y_neg and -z or z end
    if y_neg then return (z - PI_LO) - PI end
    return PI - (z - PI_LO)
end

StrictMath.pi    = PI
StrictMath.sin   = sin
StrictMath.cos   = cos
StrictMath.atan  = atan
StrictMath.atan2 = atan2

function StrictMath.deg(x)
    return x / RAD_PER_DEG
end

function StrictMath.rad(x)
    return x * RAD_PER_DEG
end

return StrictMath
