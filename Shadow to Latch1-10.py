# ============================================================
# 160-bit SHADOW REGISTER -> 10 x 16-bit LATCH DATA
# ============================================================

def shadow_to_latches(shadow_hex):

    # Remove optional 0x / 0X prefix
    shadow_hex = shadow_hex.strip().replace("_", "")

    if shadow_hex.lower().startswith("0x"):
        shadow_hex = shadow_hex[2:]

    # 160 bits = 40 hexadecimal digits
    if len(shadow_hex) != 40:
        raise ValueError(
            "Shadow register must contain exactly 40 hexadecimal digits "
            "(160 bits)."
        )

    # Convert HEX -> integer
    shadow = int(shadow_hex, 16)

    # --------------------------------------------------------
    # Extract physical IO groups from shadow
    # --------------------------------------------------------

    # Latch 1
    latch1 = (
        ((shadow >> 32) & 0xFF) << 8
        | ((shadow >> 0) & 0xFF)
    )

    # Latch 2
    latch2 = (
        ((shadow >> 48) & 0xFF) << 8
        | ((shadow >> 16) & 0xFF)
    )

    # Latch 3
    latch3 = (
        ((shadow >> 24) & 0xFF) << 8
        | ((shadow >> 8) & 0xFF)
    )

    # Latch 4
    latch4 = (
        ((shadow >> 80) & 0xFF) << 8
        | ((shadow >> 64) & 0xFF)
    )

    # Latch 5
    latch5 = (
        ((shadow >> 112) & 0xFF) << 8
        | ((shadow >> 96) & 0xFF)
    )

    # Latch 6
    latch6 = (
        ((shadow >> 56) & 0xFF) << 8
        | ((shadow >> 40) & 0xFF)
    )

    # Latch 7
    latch7 = (
        ((shadow >> 144) & 0xFF) << 8
        | ((shadow >> 128) & 0xFF)
    )

    # Latch 8
    latch8 = (
        ((shadow >> 88) & 0xFF) << 8
        | ((shadow >> 72) & 0xFF)
    )

    # Latch 9
    latch9 = (
        ((shadow >> 120) & 0xFF) << 8
        | ((shadow >> 104) & 0xFF)
    )

    # Latch 10
    latch10 = (
        ((shadow >> 152) & 0xFF) << 8
        | ((shadow >> 136) & 0xFF)
    )

    return [
        latch1,
        latch2,
        latch3,
        latch4,
        latch5,
        latch6,
        latch7,
        latch8,
        latch9,
        latch10,
    ]


# ============================================================
# MAIN
# ============================================================

shadow_hex = input(
    "Enter 160-bit shadow register HEX (40 digits): "
)

try:

    latches = shadow_to_latches(shadow_hex)

    print("\n==============================================")
    print("SHADOW REGISTER")
    print("==============================================")
    print(shadow_hex.upper().replace("0X", ""))

    print("\n==============================================")
    print("LATCH DATA")
    print("==============================================")

    for i, value in enumerate(latches, start=1):

        print(
            f"LATCH {i:2d} : "
            f"HEX = {value:04X}    "
            f"BIN = {value:016b}"
        )

    print("\n==============================================")
    print("VHDL FORMAT")
    print("==============================================")

    for i, value in enumerate(latches, start=1):

        print(
            f'LATCH{i}_DATA <= x"{value:04X}";'
        )

except ValueError as e:

    print(f"\nERROR: {e}")