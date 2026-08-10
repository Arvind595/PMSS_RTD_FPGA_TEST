# ============================================================
# VHDL Relay / Latch Mapping Verification Tool
#
# FPGA:
#   50 MHz
#
# Resistance:
#   256, 128, 64, 32, 16, 8, 4, 2, 1, 0.5 ohms
#
# Relay logic:
#   Q = 1 -> Relay ON  -> resistor BYPASSED
#   Q = 0 -> Relay OFF -> resistor INSERTED
#
# Resistance code:
#   bit 9 = 256 ohm
#   bit 8 = 128 ohm
#   ...
#   bit 1 = 1 ohm
#   bit 0 = 0.5 ohm
#
# shadow mapping:
#   shadow[0:15]     = 256 ohm
#   shadow[16:31]    = 128 ohm
#   shadow[32:47]    = 64 ohm
#   shadow[48:63]    = 32 ohm
#   shadow[64:79]    = 16 ohm
#   shadow[80:95]    = 8 ohm
#   shadow[96:111]   = 4 ohm
#   shadow[112:127]  = 2 ohm
#   shadow[128:143]  = 1 ohm
#   shadow[144:159]  = 0.5 ohm
#
# Each group:
#   bit 0  = CH0
#   bit 1  = CH1
#   ...
#   bit 15 = CH15
#
# Latch physical mapping:
#
# Latch 1:
#   Q0-Q7   = IO[0:7]
#   Q8-Q15  = IO[32:39]
#
# Latch 2:
#   Q0-Q7   = IO[16:23]
#   Q8-Q15  = IO[48:55]
#
# Latch 3:
#   Q0-Q7   = IO[8:15]
#   Q8-Q15  = IO[24:31]
#
# Latch 4:
#   Q0-Q7   = IO[64:71]
#   Q8-Q15  = IO[80:87]
#
# Latch 5:
#   Q0-Q7   = IO[96:103]
#   Q8-Q15  = IO[112:119]
#
# Latch 6:
#   Q0-Q7   = IO[40:47]
#   Q8-Q15  = IO[56:63]
#
# Latch 7:
#   Q0-Q7   = IO[128:135]
#   Q8-Q15  = IO[144:151]
#
# Latch 8:
#   Q0-Q7   = IO[72:79]
#   Q8-Q15  = IO[88:95]
#
# Latch 9:
#   Q0-Q7   = IO[104:111]
#   Q8-Q15  = IO[120:127]
#
# Latch 10:
#   Q0-Q7   = IO[136:143]
#   Q8-Q15  = IO[152:159]
# ============================================================


RESISTOR_VALUES = [
    256.0,
    128.0,
    64.0,
    32.0,
    16.0,
    8.0,
    4.0,
    2.0,
    1.0,
    0.5
]


def resistance_to_code(resistance):
    """
    Convert resistance to 10-bit code.

    0.5 ohm  -> 0000000001
    1.0 ohm  -> 0000000010
    1.5 ohm  -> 0000000011
    ...
    511.5    -> 1111111111

    Code represents resistance in units of 0.5 ohm.
    """

    # Check that resistance is in 0.5 ohm increments
    doubled = round(resistance * 2)

    if abs(resistance * 2 - doubled) > 1e-9:
        raise ValueError(
            "Resistance must be in 0.5 ohm increments."
        )

    if doubled < 1 or doubled > 1023:
        raise ValueError(
            "Resistance must be between 0.5 and 511.5 ohms."
        )

    return doubled


def code_to_resistance(code):
    """Convert 10-bit code back to resistance."""

    return code * 0.5


def get_relay_pattern(resistance_code):
    """
    Relay pattern is inverted relative to resistance code.

    Code bit = 1 -> resistor required
                   -> relay OFF
                   -> Q = 0

    Code bit = 0 -> resistor not required
                   -> relay ON
                   -> Q = 1

    Therefore:
        relay_pattern = NOT(resistance_code)
    """

    return (~resistance_code) & 0x3FF


def update_shadow(channel, resistance_code, shadow=None):
    """
    Update only one channel in the 160-bit shadow register.

    Existing shadow contents for the other 15 channels are preserved.
    """

    if not 0 <= channel <= 15:
        raise ValueError("Channel must be between 0 and 15.")

    if shadow is None:
        # Default:
        # all relay outputs OFF
        # all resistors INSERTED
        # all channels = 511.5 ohm
        shadow = 0

    relay_pattern = get_relay_pattern(resistance_code)

    # Resistance bit mapping:
    #
    # resistance_code bit 9 -> shadow group 0 -> 256 ohm
    # resistance_code bit 8 -> shadow group 1 -> 128 ohm
    # ...
    # resistance_code bit 0 -> shadow group 9 -> 0.5 ohm

    for resistance_bit in range(10):

        group = 9 - resistance_bit

        shadow_index = group * 16 + channel

        relay_bit = (relay_pattern >> resistance_bit) & 1

        if relay_bit:
            shadow |= (1 << shadow_index)
        else:
            shadow &= ~(1 << shadow_index)

    return shadow


def shadow_bit(shadow, index):
    """Return one shadow bit."""

    return (shadow >> index) & 1


def make_latch_values(shadow):
    """
    Convert 160-bit shadow register into the ten physical
    16-bit latch values.
    """

    latch = {}

    # Latch 1
    latch[1] = (
        ((shadow >> 32) & 0xFF) << 8
        | ((shadow >> 0) & 0xFF)
    )

    # Latch 2
    latch[2] = (
        ((shadow >> 48) & 0xFF) << 8
        | ((shadow >> 16) & 0xFF)
    )

    # Latch 3
    latch[3] = (
        ((shadow >> 24) & 0xFF) << 8
        | ((shadow >> 8) & 0xFF)
    )

    # Latch 4
    latch[4] = (
        ((shadow >> 80) & 0xFF) << 8
        | ((shadow >> 64) & 0xFF)
    )

    # Latch 5
    latch[5] = (
        ((shadow >> 112) & 0xFF) << 8
        | ((shadow >> 96) & 0xFF)
    )

    # Latch 6
    latch[6] = (
        ((shadow >> 56) & 0xFF) << 8
        | ((shadow >> 40) & 0xFF)
    )

    # Latch 7
    latch[7] = (
        ((shadow >> 144) & 0xFF) << 8
        | ((shadow >> 128) & 0xFF)
    )

    # Latch 8
    latch[8] = (
        ((shadow >> 88) & 0xFF) << 8
        | ((shadow >> 72) & 0xFF)
    )

    # Latch 9
    latch[9] = (
        ((shadow >> 120) & 0xFF) << 8
        | ((shadow >> 104) & 0xFF)
    )

    # Latch 10
    latch[10] = (
        ((shadow >> 152) & 0xFF) << 8
        | ((shadow >> 136) & 0xFF)
    )

    return latch


def print_shadow(shadow):
    """Print complete shadow register."""

    binary = format(shadow, "0160b")

    print("\n============================================================")
    print("SHADOW REGISTER")
    print("============================================================")

    print("\nshadow[159:0]:")
    print(binary)

    print("\nShadow grouped by resistance:")

    groups = [
        ("256", 0),
        ("128", 16),
        ("64", 32),
        ("32", 48),
        ("16", 64),
        ("8", 80),
        ("4", 96),
        ("2", 112),
        ("1", 128),
        ("0.5", 144),
    ]

    for name, start in groups:

        value = (shadow >> start) & 0xFFFF

        print(
            f"{name:>5} ohm : "
            f"shadow[{start+15:3d}:{start:3d}] = "
            f"{value:04X} = {value:016b}"
        )


def print_latches(latches):
    """Print all latch values."""

    print("\n============================================================")
    print("10 × 16-BIT LATCH VALUES")
    print("============================================================")

    bus_mapping = {
        1: "BUS1",
        2: "BUS1",
        3: "BUS1",
        4: "BUS2",
        5: "BUS2",
        6: "BUS2",
        7: "BUS3",
        8: "BUS3",
        9: "BUS3",
        10: "BUS3",
    }

    for n in range(1, 11):

        value = latches[n]

        print(
            f"LATCH {n:2d}  "
            f"{bus_mapping[n]:4s}  "
            f"HEX = {value:04X}  "
            f"BIN = {value:016b}"
        )


def print_channel_details(channel, resistance, code, relay_pattern):
    """Print the ten relay states for the selected channel."""

    print("\n============================================================")
    print("SELECTED CHANNEL")
    print("============================================================")

    print(f"Channel              : CH{channel}")
    print(f"Requested resistance : {resistance:g} ohm")
    print(f"Resistance code      : {code:010b}")
    print(f"Relay pattern        : {relay_pattern:010b}")

    print("\nRelay mapping:")
    print(
        "Resistance     Code bit     Relay Q     Shadow index     State"
    )
    print("-" * 70)

    for resistance_bit in range(9, -1, -1):

        r = 2 ** (resistance_bit - 1)

        if resistance_bit == 0:
            r = 0.5

        code_bit = (code >> resistance_bit) & 1
        relay_bit = (relay_pattern >> resistance_bit) & 1

        group = 9 - resistance_bit
        index = group * 16 + channel

        if relay_bit:
            state = "BYPASSED"
        else:
            state = "INSERTED"

        print(
            f"{r:8g} ohm      "
            f"{code_bit:1d}           "
            f"{relay_bit:1d}          "
            f"{index:3d}          "
            f"{state}"
        )


def main():

    print("============================================================")
    print(" FPGA 160-BIT RELAY / LATCH VERIFICATION TOOL")
    print("============================================================")

    try:
        channel = int(input("\nEnter channel (0-15): "))

        resistance = float(
            input("Enter resistance in ohms (0.5-511.5): ")
        )

        code = resistance_to_code(resistance)

        relay_pattern = get_relay_pattern(code)

        # Start from default state:
        # all channels = 511.5 ohm
        shadow = update_shadow(
            channel=channel,
            resistance_code=code,
            shadow=None
        )

        latches = make_latch_values(shadow)

        print_channel_details(
            channel,
            resistance,
            code,
            relay_pattern
        )

        print_shadow(shadow)

        print_latches(latches)

        print("\n============================================================")
        print("SUMMARY")
        print("============================================================")

        print(f"CH{channel} = {resistance:g} ohm")
        print(f"Resistance code = {code:010b}")
        print(f"Relay pattern   = {relay_pattern:010b}")

        print("\nLatch HEX values:")

        for n in range(1, 11):
            print(f"L{n:02d} = {latches[n]:04X}")

        print("\nLatch VHDL-style values:")

        for n in range(1, 11):
            print(
                f'LATCH{n}_DATA = x"{latches[n]:04X}";'
            )

    except ValueError as e:
        print(f"\nERROR: {e}")


if __name__ == "__main__":
    main()