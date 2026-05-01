// Swift 99/a
//
// SpeechCoefficients.swift
// LPC coefficient tables for the TMS5200/CD2501E speech synthesizer.
// Sourced from MAME tms5110r.hxx — T0285_2501E_coeff (the specific chip
// variant used in the TI-99/4A Speech Synthesizer module).
//
// These tables define the quantization levels for: energy, pitch, and
// 10 reflection coefficients (K1–K10) used in the lattice filter, plus
// the chirp excitation waveform for voiced sounds.
//
// license: BSD-3-Clause
// copyright-holders: Frank Palazzolo, Couriersud, Jonathan Gevaryahu

import Foundation

// Coefficient structure matching MAME's tms5100_coeffs
struct TMS5200Coefficients {
    let numK: Int
    let energyBits: Int
    let pitchBits: Int
    let kBits: [Int]              // bit widths for K1..K10
    let energyTable: [Int]        // 16 entries
    let pitchTable: [Int]         // 64 entries for TMS5200
    let kTable: [[Int]]           // K1..K10 tables (varying sizes)
    let chirpTable: [Int16]       // 52 entries, signed
    let interpCoeff: [Int]        // 8 entries (shift amounts)
}

/// TMS5200 / CD2501E coefficients — the chip used in the TI-99/4A PHP1500 Speech Module
let tms5200Coeff = TMS5200Coefficients(
    numK: 10,
    energyBits: 4,
    pitchBits: 6,
    kBits: [5, 5, 4, 4, 4, 4, 4, 3, 3, 3],

    // TI_028X_LATER_ENERGY
    energyTable: [
        0,  1,  2,  3,  4,  6,  8, 11,
       16, 23, 33, 47, 63, 85,114,  0
    ],

    // TI_2501E_PITCH (64 entries)
    pitchTable: [
          0,  14,  15,  16,  17,  18,  19,  20,
         21,  22,  23,  24,  25,  26,  27,  28,
         29,  30,  31,  32,  34,  36,  38,  40,
         41,  43,  45,  48,  49,  51,  54,  55,
         57,  60,  62,  64,  68,  72,  74,  76,
         81,  85,  87,  90,  96,  99, 103, 107,
        112, 117, 122, 127, 133, 139, 145, 151,
        157, 164, 171, 178, 186, 194, 202, 211
    ],

    // TI_2801_2501E_LPC
    kTable: [
        // K1 (32 entries, 5-bit index)
        [-501, -498, -495, -490, -485, -478, -469, -459,
         -446, -431, -412, -389, -362, -331, -295, -253,
         -207, -156, -102,  -45,   13,   70,  126,  179,
          228,  272,  311,  345,  374,  399,  420,  437],
        // K2 (32 entries, 5-bit index)
        [-376, -357, -335, -312, -286, -258, -227, -195,
         -161, -124,  -87,  -49,  -10,   29,   68,  106,
          143,  178,  212,  243,  272,  299,  324,  346,
          366,  384,  400,  414,  427,  438,  448,  506],
        // K3 (16 entries, 4-bit index)
        [-407, -381, -349, -311, -268, -218, -162, -102,
          -39,   25,   89,  149,  206,  257,  302,  341],
        // K4 (16 entries, 4-bit index)
        [-290, -252, -209, -163, -114,  -62,   -9,   44,
           97,  147,  194,  238,  278,  313,  344,  371],
        // K5 (16 entries, 4-bit index)
        [-318, -283, -245, -202, -156, -107,  -56,   -3,
           49,  101,  150,  196,  239,  278,  313,  344],
        // K6 (16 entries, 4-bit index)
        [-193, -152, -109,  -65,  -20,   26,   71,  115,
          158,  198,  235,  270,  301,  330,  355,  377],
        // K7 (16 entries, 4-bit index)
        [-254, -218, -180, -140,  -97,  -53,   -8,   36,
           81,  124,  165,  204,  240,  274,  304,  332],
        // K8 (8 entries, 3-bit index)
        [-205, -112,  -10,   92,  187,  269,  336,  387],
        // K9 (8 entries, 3-bit index)
        [-249, -183, -110,  -32,   48,  126,  198,  261],
        // K10 (8 entries, 3-bit index)
        [-190, -133,  -73,  -10,   53,  115,  173,  227]
    ],

    // TI_LATER_CHIRP (signed int16 values)
    chirpTable: [
        0x00, 0x03, 0x0f, 0x28, 0x4c, 0x6c, 0x71, 0x50,
        0x25, 0x26, 0x4c, 0x44, 0x1a, 0x32, 0x3b, 0x13,
        0x37, 0x1a, 0x25, 0x1f, 0x1d, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00
    ],

    // TI_INTERP
    interpCoeff: [0, 3, 3, 3, 2, 2, 1, 1]
)
