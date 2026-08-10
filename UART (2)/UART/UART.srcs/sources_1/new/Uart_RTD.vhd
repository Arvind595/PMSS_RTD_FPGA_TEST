----------------------------------------------------------------------------------
-- Module Name: CH1_RTD - Behavioral
-- Description: Interactive RTD Channel & Resistance Controller over RS422 / UART.
-- Flow:
--   1. Prompts "SET CHANNEL: " over UART TX.
--   2. Receives channel number (0-15) from user over RX, echoing characters.
--   3. Prompts "SET RESISTANCE: " over UART TX.
--   4. Receives resistance value (0-1023) from user over RX, echoing characters.
--   5. Stores channel and resistance, updates Relay Latches (1 to 10).
--   6. Transmits confirmation: "STORED -> CH: XX, RES: YYYY OHM\r\n\r\n".
--   7. Repeats flow for next setting.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity CH1_RTD is
    Port (
        ------------------------------------------------------------------
        -- 50 MHz FPGA Clock & Reset
        ------------------------------------------------------------------
        FPGA_CLK_50MHZ : in std_logic;
        RESET_SW       : in std_logic; -- Active LOW reset switch

        ------------------------------------------------------------------
        -- RS422 Transmit & Receive Pins
        ------------------------------------------------------------------
        RS422_TX       : out std_logic;
        RS422_RX       : in  std_logic := '1';
        RS422_TX_EN    : out std_logic;
        RS422_TX_nEN   : out std_logic;

        ------------------------------------------------------------------
        -- Status
        ------------------------------------------------------------------
        FP_STS1        : out std_logic;
        FP_STS2        : out std_logic;

        ------------------------------------------------------------------
        -- Latch Output Enable & Latch Enable (Active Low)
        ------------------------------------------------------------------
        F_nOE          : out std_logic_vector(9 downto 0);
        F_nLE          : out std_logic_vector(9 downto 0);

        ------------------------------------------------------------------
        -- Relay/Latch Data Busses
        ------------------------------------------------------------------
        F1_LD          : out std_logic_vector(15 downto 0);
        F2_LD          : out std_logic_vector(15 downto 0);
        F3_LD          : out std_logic_vector(15 downto 0)
    );
end CH1_RTD;

architecture Behavioral of CH1_RTD is

    ------------------------------------------------------------------
    -- Clock & Baud Rate Constants (50 MHz, 9600 Baud)
    ------------------------------------------------------------------
    constant CLOCK_FREQ    : integer := 50000000;
    constant BAUD_RATE     : integer := 9600;
    constant CLKS_PER_BIT  : integer := CLOCK_FREQ / BAUD_RATE; -- 5208 clocks
    constant HALF_BIT_CLK  : integer := CLKS_PER_BIT / 2;       -- 2604 clocks

    ------------------------------------------------------------------
    -- Prompt & Message Constants
    ------------------------------------------------------------------
    -- Message 1: "SET CHANNEL: " (13 bytes)
    type STRING_CH_TYPE is array (0 to 12) of std_logic_vector(7 downto 0);
    constant MSG_SET_CH : STRING_CH_TYPE := (
        x"53", x"45", x"54", x"20", -- S E T _
        x"43", x"48", x"41", x"4E", x"4E", x"45", x"4C", x"3A", x"20" -- C H A N N E L : _
    );

    -- Message 2: "\r\nSET RESISTANCE: " (18 bytes)
    type STRING_RES_TYPE is array (0 to 17) of std_logic_vector(7 downto 0);
    constant MSG_SET_RES : STRING_RES_TYPE := (
        x"0D", x"0A", -- \r \n
        x"53", x"45", x"54", x"20", -- S E T _
        x"52", x"45", x"53", x"49", x"53", x"54", x"41", x"4E", x"43", x"45", x"3A", x"20" -- R E S I S T A N C E : _
    );

    -- Message 3 Prefix: "\r\nSTORED -> CH: " (16 bytes)
    type STRING_CONF_PRE_TYPE is array (0 to 15) of std_logic_vector(7 downto 0);
    constant MSG_CONF_PRE : STRING_CONF_PRE_TYPE := (
        x"0D", x"0A", -- \r \n
        x"53", x"54", x"4F", x"52", x"45", x"44", x"20", x"2D", x"3E", x"20", -- S T O R E D _ - > _
        x"43", x"48", x"3A", x"20" -- C H : _
    );

    -- Message 3 Mid: ", RES: " (7 bytes)
    type STRING_CONF_MID_TYPE is array (0 to 6) of std_logic_vector(7 downto 0);
    constant MSG_CONF_MID : STRING_CONF_MID_TYPE := (
        x"2C", x"20", x"52", x"45", x"53", x"3A", x"20" -- , _ R E S : _
    );

    -- Message 3 Suffix: " OHM\r\n\r\n" (8 bytes)
    type STRING_CONF_SUF_TYPE is array (0 to 7) of std_logic_vector(7 downto 0);
    constant MSG_CONF_SUF : STRING_CONF_SUF_TYPE := (
        x"20", x"4F", x"48", x"4D", x"0D", x"0A", x"0D", x"0A" -- _ O H M \r \n \r \n
    );

    ------------------------------------------------------------------
    -- Master Flow FSM States
    ------------------------------------------------------------------
    type FLOW_STATE_TYPE is (
        ST_RESET,
        -- Prompt Channel
        ST_SEND_PROMPT_CH,
        ST_WAIT_PROMPT_CH_TX,
        -- Receive Channel Number
        ST_RX_CH_BYTE,
        ST_PARSE_CH,
        -- Prompt Resistance
        ST_SEND_PROMPT_RES,
        ST_WAIT_PROMPT_RES_TX,
        -- Receive Resistance Value
        ST_RX_RES_BYTE,
        ST_PARSE_RES,
        -- Process & Store
        ST_STORE_AND_APPLY,
        -- Send Confirmation
        ST_SEND_CONF_PRE,
        ST_WAIT_CONF_PRE,
        ST_SEND_CONF_CH_DIGITS,
        ST_WAIT_CONF_CH_DIGITS,
        ST_SEND_CONF_MID,
        ST_WAIT_CONF_MID,
        ST_SEND_CONF_RES_DIGITS,
        ST_WAIT_CONF_RES_DIGITS,
        ST_SEND_CONF_SUF,
        ST_WAIT_CONF_SUF
    );

    signal flow_state : FLOW_STATE_TYPE := ST_RESET;

    ------------------------------------------------------------------
    -- UART Transmitter Signals
    ------------------------------------------------------------------
    type UART_TX_STATE_TYPE is (TX_IDLE, TX_START_BIT, TX_DATA_BITS, TX_STOP_BIT, TX_DONE_ST);
    signal tx_state       : UART_TX_STATE_TYPE := TX_IDLE;
    signal tx_baud_count  : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal tx_bit_index   : integer range 0 to 7 := 0;
    signal tx_data_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_start_pulse : std_logic := '0';
    signal tx_busy        : std_logic := '0';
    signal tx_done        : std_logic := '0';
    signal tx_line        : std_logic := '1';

    ------------------------------------------------------------------
    -- UART Receiver Signals
    ------------------------------------------------------------------
    type UART_RX_STATE_TYPE is (RX_IDLE, RX_START_BIT, RX_DATA_BITS, RX_STOP_BIT);
    signal rx_state       : UART_RX_STATE_TYPE := RX_IDLE;
    signal rx_baud_count  : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal rx_bit_index   : integer range 0 to 7 := 0;
    signal rx_shift_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid       : std_logic := '0';

    -- Double Synchronizer for RX line to prevent metastability
    signal rx_sync1       : std_logic := '1';
    signal rx_sync2       : std_logic := '1';

    ------------------------------------------------------------------
    -- Response Buffer & Counters
    ------------------------------------------------------------------
    type RX_BUFFER_TYPE is array (0 to 15) of std_logic_vector(7 downto 0);
    signal rx_buffer      : RX_BUFFER_TYPE := (others => (others => '0'));
    signal rx_buf_len     : integer range 0 to 16 := 0;
    signal msg_idx        : integer range 0 to 31 := 0;
    signal sub_idx        : integer range 0 to 7 := 0;

    ------------------------------------------------------------------
    -- Relay Latch Registers & Channel Memory
    ------------------------------------------------------------------
    type latch_array_t is array (1 to 10) of std_logic_vector(15 downto 0);
    signal latch_reg      : latch_array_t := (others => (others => '0'));

    type stored_res_array_t is array (0 to 15) of std_logic_vector(9 downto 0);
    signal stored_res     : stored_res_array_t := (others => (others => '0'));

    signal channel_sel    : integer range 0 to 15 := 0;
    signal res_int        : integer range 0 to 1023 := 0;
    signal res_code       : std_logic_vector(9 downto 0) := (others => '0');

begin

    ------------------------------------------------------------------
    -- Physical RS422 Transceiver Control & Status Outputs
    ------------------------------------------------------------------
    RS422_TX     <= tx_line;
    RS422_TX_EN  <= '1'; -- Enable TX driver
    RS422_TX_nEN <= '0'; -- Enable RX driver

    FP_STS1      <= '1';
    FP_STS2      <= tx_busy;

    ------------------------------------------------------------------
    -- Latch Control Outputs
    ------------------------------------------------------------------
    F_nOE <= (others => '0'); -- Enable outputs (Active Low)
    F_nLE <= (others => '0'); -- Transparent Latch Enable (Active Low)

    ------------------------------------------------------------------
    -- Latch Driver Busses
    ------------------------------------------------------------------
    F1_LD <= latch_reg(1) or latch_reg(2) or latch_reg(3);
    F2_LD <= latch_reg(4) or latch_reg(5) or latch_reg(6);
    F3_LD <= latch_reg(7) or latch_reg(8) or latch_reg(9) or latch_reg(10);

    ------------------------------------------------------------------
    -- Synchronize RS422 RX Line
    ------------------------------------------------------------------
    process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            rx_sync1 <= RS422_RX;
            rx_sync2 <= rx_sync1;
        end if;
    end process;

    ------------------------------------------------------------------
    -- UART TRANSMITTER PROCESS
    ------------------------------------------------------------------
    UART_TX_PROC : process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            tx_done <= '0';

            case tx_state is
                when TX_IDLE =>
                    tx_line <= '1';
                    tx_busy <= '0';
                    tx_baud_count <= 0;
                    tx_bit_index  <= 0;

                    if tx_start_pulse = '1' then
                        tx_busy     <= '1';
                        tx_state    <= TX_START_BIT;
                    end if;

                when TX_START_BIT =>
                    tx_line <= '0';
                    tx_busy <= '1';
                    if tx_baud_count = CLKS_PER_BIT - 1 then
                        tx_baud_count <= 0;
                        tx_state      <= TX_DATA_BITS;
                    else
                        tx_baud_count <= tx_baud_count + 1;
                    end if;

                when TX_DATA_BITS =>
                    tx_line <= tx_data_reg(tx_bit_index);
                    tx_busy <= '1';
                    if tx_baud_count = CLKS_PER_BIT - 1 then
                        tx_baud_count <= 0;
                        if tx_bit_index = 7 then
                            tx_bit_index <= 0;
                            tx_state     <= TX_STOP_BIT;
                        else
                            tx_bit_index <= tx_bit_index + 1;
                        end if;
                    else
                        tx_baud_count <= tx_baud_count + 1;
                    end if;

                when TX_STOP_BIT =>
                    tx_line <= '1';
                    tx_busy <= '1';
                    if tx_baud_count = CLKS_PER_BIT - 1 then
                        tx_baud_count <= 0;
                        tx_state      <= TX_DONE_ST;
                    else
                        tx_baud_count <= tx_baud_count + 1;
                    end if;

                when TX_DONE_ST =>
                    tx_line  <= '1';
                    tx_busy  <= '0';
                    tx_done  <= '1';
                    tx_state <= TX_IDLE;

                when others =>
                    tx_state <= TX_IDLE;
            end case;
        end if;
    end process;

    ------------------------------------------------------------------
    -- UART RECEIVER PROCESS
    ------------------------------------------------------------------
    UART_RX_PROC : process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            rx_valid <= '0';

            case rx_state is
                when RX_IDLE =>
                    rx_baud_count <= 0;
                    rx_bit_index  <= 0;
                    if rx_sync2 = '0' then -- Start bit detected
                        rx_state <= RX_START_BIT;
                    end if;

                when RX_START_BIT =>
                    if rx_baud_count = HALF_BIT_CLK then
                        if rx_sync2 = '0' then -- Validate start bit at middle
                            rx_baud_count <= 0;
                            rx_state      <= RX_DATA_BITS;
                        else
                            rx_state      <= RX_IDLE;
                        end if;
                    else
                        rx_baud_count <= rx_baud_count + 1;
                    end if;

                when RX_DATA_BITS =>
                    if rx_baud_count = CLKS_PER_BIT - 1 then
                        rx_baud_count <= 0;
                        rx_shift_reg(rx_bit_index) <= rx_sync2;

                        if rx_bit_index = 7 then
                            rx_bit_index <= 0;
                            rx_state     <= RX_STOP_BIT;
                        else
                            rx_bit_index <= rx_bit_index + 1;
                        end if;
                    else
                        rx_baud_count <= rx_baud_count + 1;
                    end if;

                when RX_STOP_BIT =>
                    if rx_baud_count = CLKS_PER_BIT - 1 then
                        rx_baud_count <= 0;
                        rx_byte       <= rx_shift_reg;
                        rx_valid      <= '1'; -- Byte complete
                        rx_state      <= RX_IDLE;
                    else
                        rx_baud_count <= rx_baud_count + 1;
                    end if;

                when others =>
                    rx_state <= RX_IDLE;
            end case;
        end if;
    end process;

    ------------------------------------------------------------------
    -- MASTER FLOW FSM: PROMPT CH -> RX CH -> PROMPT RES -> RX RES -> STORE -> CONFIRM
    ------------------------------------------------------------------
    FLOW_PROC : process(FPGA_CLK_50MHZ)
        variable ch_num    : integer range 0 to 15;
        variable ch_idx    : integer range 0 to 7;
        variable temp_val  : integer range 0 to 4095;
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            tx_start_pulse <= '0';

            -- Reset condition
            if RESET_SW = '0' then
                flow_state  <= ST_RESET;
            else
                case flow_state is

                    ------------------------------------------------------
                    -- ST_RESET: Reset variables and start prompt sequence
                    ------------------------------------------------------
                    when ST_RESET =>
                        msg_idx    <= 0;
                        sub_idx    <= 0;
                        rx_buf_len <= 0;
                        flow_state <= ST_SEND_PROMPT_CH;

                    ------------------------------------------------------
                    -- ST_SEND_PROMPT_CH: Send "SET CHANNEL: "
                    ------------------------------------------------------
                    when ST_SEND_PROMPT_CH =>
                        if tx_busy = '0' then
                            tx_data_reg    <= MSG_SET_CH(msg_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_PROMPT_CH_TX;
                        end if;

                    when ST_WAIT_PROMPT_CH_TX =>
                        if tx_done = '1' then
                            if msg_idx = 12 then -- 13 bytes complete
                                msg_idx    <= 0;
                                rx_buf_len <= 0;
                                flow_state <= ST_RX_CH_BYTE;
                            else
                                msg_idx    <= msg_idx + 1;
                                flow_state <= ST_SEND_PROMPT_CH;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_RX_CH_BYTE: Receive Channel string from user
                    ------------------------------------------------------
                    when ST_RX_CH_BYTE =>
                        if rx_valid = '1' then
                            -- Check for Carriage Return (\r) or Line Feed (\n)
                            if rx_byte = x"0D" or rx_byte = x"0A" then
                                if rx_buf_len > 0 then
                                    flow_state <= ST_PARSE_CH;
                                end if;
                            -- Check for ASCII Digits ('0' to '9')
                            elsif rx_byte >= x"30" and rx_byte <= x"39" then
                                if rx_buf_len < 15 then
                                    rx_buffer(rx_buf_len) <= rx_byte;
                                    rx_buf_len            <= rx_buf_len + 1;
                                end if;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_PARSE_CH: Convert ASCII string to Channel integer
                    ------------------------------------------------------
                    when ST_PARSE_CH =>
                        temp_val := 0;
                        for i in 0 to 3 loop
                            if i < rx_buf_len then
                                if rx_buffer(i) >= x"30" and rx_buffer(i) <= x"39" then
                                    temp_val := temp_val * 10 + (to_integer(unsigned(rx_buffer(i))) - 48);
                                end if;
                            end if;
                        end loop;

                        if temp_val > 15 then
                            temp_val := 15;
                        end if;

                        channel_sel <= temp_val;
                        msg_idx     <= 0;
                        rx_buf_len  <= 0;
                        flow_state  <= ST_SEND_PROMPT_RES;

                    ------------------------------------------------------
                    -- ST_SEND_PROMPT_RES: Send "\r\nSET RESISTANCE: "
                    ------------------------------------------------------
                    when ST_SEND_PROMPT_RES =>
                        if tx_busy = '0' then
                            tx_data_reg    <= MSG_SET_RES(msg_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_PROMPT_RES_TX;
                        end if;

                    when ST_WAIT_PROMPT_RES_TX =>
                        if tx_done = '1' then
                            if msg_idx = 17 then -- 18 bytes complete
                                msg_idx    <= 0;
                                rx_buf_len <= 0;
                                flow_state <= ST_RX_RES_BYTE;
                            else
                                msg_idx    <= msg_idx + 1;
                                flow_state <= ST_SEND_PROMPT_RES;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_RX_RES_BYTE: Receive Resistance string from user
                    ------------------------------------------------------
                    when ST_RX_RES_BYTE =>
                        if rx_valid = '1' then
                            -- Check for Carriage Return (\r) or Line Feed (\n)
                            if rx_byte = x"0D" or rx_byte = x"0A" then
                                if rx_buf_len > 0 then
                                    flow_state <= ST_PARSE_RES;
                                end if;
                            -- Check for ASCII Digits ('0' to '9')
                            elsif rx_byte >= x"30" and rx_byte <= x"39" then
                                if rx_buf_len < 15 then
                                    rx_buffer(rx_buf_len) <= rx_byte;
                                    rx_buf_len            <= rx_buf_len + 1;
                                end if;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_PARSE_RES: Convert ASCII string to Resistance integer
                    ------------------------------------------------------
                    when ST_PARSE_RES =>
                        temp_val := 0;
                        for i in 0 to 3 loop
                            if i < rx_buf_len then
                                if rx_buffer(i) >= x"30" and rx_buffer(i) <= x"39" then
                                    temp_val := temp_val * 10 + (to_integer(unsigned(rx_buffer(i))) - 48);
                                end if;
                            end if;
                        end loop;

                        if temp_val > 1023 then
                            temp_val := 1023;
                        end if;

                        res_int    <= temp_val;
                        res_code   <= std_logic_vector(to_unsigned(temp_val, 10));
                        flow_state <= ST_STORE_AND_APPLY;

                    ------------------------------------------------------
                    -- ST_STORE_AND_APPLY: Store in array & Update Latches
                    ------------------------------------------------------
                    when ST_STORE_AND_APPLY =>
                        stored_res(channel_sel) <= res_code;

                        ch_num := channel_sel;
                        -- Apply mapping table to Latches 1..10
                        if ch_num < 8 then
                            ch_idx := ch_num;
                            latch_reg(1)(ch_idx)     <= res_code(9); -- 256 Ω
                            latch_reg(1)(ch_idx + 8) <= res_code(7); --  64 Ω
                            latch_reg(2)(ch_idx)     <= res_code(8); -- 128 Ω
                            latch_reg(2)(ch_idx + 8) <= res_code(6); --  32 Ω
                            latch_reg(4)(ch_idx)     <= res_code(5); --  16 Ω
                            latch_reg(4)(ch_idx + 8) <= res_code(4); --   8 Ω
                            latch_reg(5)(ch_idx)     <= res_code(3); --   4 Ω
                            latch_reg(5)(ch_idx + 8) <= res_code(2); --   2 Ω
                            latch_reg(7)(ch_idx)     <= res_code(1); --   1 Ω
                            latch_reg(7)(ch_idx + 8) <= res_code(0); -- 0.5 Ω
                        else
                            ch_idx := ch_num - 8;
                            latch_reg(3)(ch_idx)     <= res_code(9); -- 256 Ω
                            latch_reg(3)(ch_idx + 8) <= res_code(8); -- 128 Ω
                            latch_reg(6)(ch_idx)     <= res_code(7); --  64 Ω
                            latch_reg(6)(ch_idx + 8) <= res_code(6); --  32 Ω
                            latch_reg(8)(ch_idx)     <= res_code(5); --  16 Ω
                            latch_reg(8)(ch_idx + 8) <= res_code(4); --   8 Ω
                            latch_reg(9)(ch_idx)     <= res_code(3); --   4 Ω
                            latch_reg(9)(ch_idx + 8) <= res_code(2); --   2 Ω
                            latch_reg(10)(ch_idx)    <= res_code(1); --   1 Ω
                            latch_reg(10)(ch_idx + 8)<= res_code(0); -- 0.5 Ω
                        end if;

                        msg_idx    <= 0;
                        flow_state <= ST_SEND_CONF_PRE;

                    ------------------------------------------------------
                    -- ST_SEND_CONF_PRE: Transmit "\r\nSTORED -> CH: "
                    ------------------------------------------------------
                    when ST_SEND_CONF_PRE =>
                        if tx_busy = '0' then
                            tx_data_reg    <= MSG_CONF_PRE(msg_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_CONF_PRE;
                        end if;

                    when ST_WAIT_CONF_PRE =>
                        if tx_done = '1' then
                            if msg_idx = 15 then -- 16 bytes complete
                                sub_idx    <= 0;
                                flow_state <= ST_SEND_CONF_CH_DIGITS;
                            else
                                msg_idx    <= msg_idx + 1;
                                flow_state <= ST_SEND_CONF_PRE;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_SEND_CONF_CH_DIGITS: Transmit 2 ASCII digits for CH #
                    ------------------------------------------------------
                    when ST_SEND_CONF_CH_DIGITS =>
                        if tx_busy = '0' then
                            if sub_idx = 0 then
                                -- Tens digit
                                tx_data_reg <= std_logic_vector(to_unsigned(48 + (channel_sel / 10), 8));
                            else
                                -- Units digit
                                tx_data_reg <= std_logic_vector(to_unsigned(48 + (channel_sel mod 10), 8));
                            end if;
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_CONF_CH_DIGITS;
                        end if;

                    when ST_WAIT_CONF_CH_DIGITS =>
                        if tx_done = '1' then
                            if sub_idx = 1 then
                                msg_idx    <= 0;
                                flow_state <= ST_SEND_CONF_MID;
                            else
                                sub_idx    <= 1;
                                flow_state <= ST_SEND_CONF_CH_DIGITS;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_SEND_CONF_MID: Transmit ", RES: "
                    ------------------------------------------------------
                    when ST_SEND_CONF_MID =>
                        if tx_busy = '0' then
                            tx_data_reg    <= MSG_CONF_MID(msg_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_CONF_MID;
                        end if;

                    when ST_WAIT_CONF_MID =>
                        if tx_done = '1' then
                            if msg_idx = 6 then -- 7 bytes complete
                                sub_idx    <= 0;
                                flow_state <= ST_SEND_CONF_RES_DIGITS;
                            else
                                msg_idx    <= msg_idx + 1;
                                flow_state <= ST_SEND_CONF_MID;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_SEND_CONF_RES_DIGITS: Transmit 4 ASCII digits for RES
                    ------------------------------------------------------
                    when ST_SEND_CONF_RES_DIGITS =>
                        if tx_busy = '0' then
                            case sub_idx is
                                when 0 => -- Thousands
                                    tx_data_reg <= std_logic_vector(to_unsigned(48 + (res_int / 1000), 8));
                                when 1 => -- Hundreds
                                    tx_data_reg <= std_logic_vector(to_unsigned(48 + ((res_int / 100) mod 10), 8));
                                when 2 => -- Tens
                                    tx_data_reg <= std_logic_vector(to_unsigned(48 + ((res_int / 10) mod 10), 8));
                                when others => -- Units
                                    tx_data_reg <= std_logic_vector(to_unsigned(48 + (res_int mod 10), 8));
                            end case;
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_CONF_RES_DIGITS;
                        end if;

                    when ST_WAIT_CONF_RES_DIGITS =>
                        if tx_done = '1' then
                            if sub_idx = 3 then
                                msg_idx    <= 0;
                                flow_state <= ST_SEND_CONF_SUF;
                            else
                                sub_idx    <= sub_idx + 1;
                                flow_state <= ST_SEND_CONF_RES_DIGITS;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_SEND_CONF_SUF: Transmit " OHM\r\n\r\n"
                    ------------------------------------------------------
                    when ST_SEND_CONF_SUF =>
                        if tx_busy = '0' then
                            tx_data_reg    <= MSG_CONF_SUF(msg_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_CONF_SUF;
                        end if;

                    when ST_WAIT_CONF_SUF =>
                        if tx_done = '1' then
                            if msg_idx = 7 then -- 8 bytes complete
                                msg_idx    <= 0;
                                rx_buf_len <= 0;
                                -- Loop back to prompt for next channel selection
                                flow_state <= ST_SEND_PROMPT_CH;
                            else
                                msg_idx    <= msg_idx + 1;
                                flow_state <= ST_SEND_CONF_SUF;
                            end if;
                        end if;

                    when others =>
                        flow_state <= ST_RESET;
                end case;
            end if;
        end if;
    end process;

end Behavioral;