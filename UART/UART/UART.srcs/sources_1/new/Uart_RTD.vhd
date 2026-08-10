----------------------------------------------------------------------------------
-- Module Name: CH1_RTD - Behavioral
-- Description: RTD Channel & Resistance Controller over RS422 / UART.
-- Flow:
--   1. Transmits "SET CHANNEL\r\n" ONE TIME after reset.
--   2. Receives response from user via RS422 RX.
--   3. Echoes back the received user response over RS422 TX.
--   4. Updates Relay Latches (1 to 10) based on channel selection & resistance.
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
    -- Initial Prompt Message: "SET CHANNEL\r\n"
    ------------------------------------------------------------------
    type MESSAGE_ARRAY is array (0 to 12) of std_logic_vector(7 downto 0);
    constant PROMPT_MESSAGE : MESSAGE_ARRAY := (
        x"53", -- S
        x"45", -- E
        x"54", -- T
        x"20", -- Space
        x"43", -- C
        x"48", -- H
        x"41", -- A
        x"4E", -- N
        x"4E", -- N
        x"45", -- E
        x"4C", -- L
        x"0D", -- CR (\r)
        x"0A"  -- LF (\n)
    );

    ------------------------------------------------------------------
    -- Master Flow FSM States
    ------------------------------------------------------------------
    type FLOW_STATE_TYPE is (
        ST_RESET,
        ST_SEND_PROMPT_BYTE,
        ST_WAIT_PROMPT_TX,
        ST_RECEIVE_RESPONSE,
        ST_ECHO_RESPONSE_BYTE,
        ST_WAIT_ECHO_TX,
        ST_PROCESS_COMMAND,
        ST_IDLE_WAIT
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
    type RX_BUFFER_TYPE is array (0 to 31) of std_logic_vector(7 downto 0);
    signal rx_buffer      : RX_BUFFER_TYPE := (others => (others => '0'));
    signal rx_buf_len     : integer range 0 to 32 := 0;
    signal prompt_idx     : integer range 0 to 13 := 0;
    signal echo_idx       : integer range 0 to 32 := 0;

    ------------------------------------------------------------------
    -- Relay Latch Registers (Latches 1 to 10, 16 bits each)
    ------------------------------------------------------------------
    type latch_array_t is array (1 to 10) of std_logic_vector(15 downto 0);
    signal latch_reg      : latch_array_t := (others => (others => '0'));

    signal channel_sel    : integer range 0 to 15 := 0;
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
    -- MASTER FLOW FSM: 1-TIME PROMPT -> RX RESPONSE -> ECHO -> RELAYS
    ------------------------------------------------------------------
    FLOW_PROC : process(FPGA_CLK_50MHZ)
        variable ch_num : integer range 0 to 15;
        variable ch_idx : integer range 0 to 7;
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            tx_start_pulse <= '0';

            -- Reset condition
            if RESET_SW = '0' then
                flow_state <= ST_RESET;
            else
                case flow_state is

                    ------------------------------------------------------
                    -- ST_RESET: Initialize after reset switch pressed
                    ------------------------------------------------------
                    when ST_RESET =>
                        prompt_idx <= 0;
                        echo_idx   <= 0;
                        rx_buf_len <= 0;
                        flow_state <= ST_SEND_PROMPT_BYTE;

                    ------------------------------------------------------
                    -- ST_SEND_PROMPT_BYTE: Send "SET CHANNEL\r\n" 1-TIME ONLY
                    ------------------------------------------------------
                    when ST_SEND_PROMPT_BYTE =>
                        if tx_busy = '0' then
                            tx_data_reg    <= PROMPT_MESSAGE(prompt_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_PROMPT_TX;
                        end if;

                    ------------------------------------------------------
                    -- ST_WAIT_PROMPT_TX: Wait for byte transmission
                    ------------------------------------------------------
                    when ST_WAIT_PROMPT_TX =>
                        if tx_done = '1' then
                            if prompt_idx = 12 then -- All 13 prompt characters sent
                                prompt_idx <= 0;
                                rx_buf_len <= 0;
                                flow_state <= ST_RECEIVE_RESPONSE;
                            else
                                prompt_idx <= prompt_idx + 1;
                                flow_state <= ST_SEND_PROMPT_BYTE;
                            end if;
                        end if;

                    ------------------------------------------------------
                    -- ST_RECEIVE_RESPONSE: Wait for User input over RX
                    ------------------------------------------------------
                    when ST_RECEIVE_RESPONSE =>
                       if rx_valid = '1' then
                            tx_data_reg    <= rx_byte;
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_ECHO_TX;
                        end if;

                    ------------------------------------------------------
                    -- ST_ECHO_RESPONSE_BYTE: Transmit received message back to user
                    ------------------------------------------------------
                    when ST_ECHO_RESPONSE_BYTE =>
                        if tx_busy = '0' then
                            tx_data_reg    <= rx_buffer(echo_idx);
                            tx_start_pulse <= '1';
                            flow_state     <= ST_WAIT_ECHO_TX;
                        end if;

                    ------------------------------------------------------
                    -- ST_WAIT_ECHO_TX: Wait for byte echo completion
                    ------------------------------------------------------
                    when ST_WAIT_ECHO_TX =>
                       if tx_done = '1' then
                            flow_state <= ST_RECEIVE_RESPONSE;
                        end if;

                    ------------------------------------------------------
                    -- ST_PROCESS_COMMAND: Parse response & Update Relay Latches
                    ------------------------------------------------------
                    when ST_PROCESS_COMMAND =>
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

                        -- Return to listening state for next user command
                        rx_buf_len <= 0;
                        flow_state <= ST_RECEIVE_RESPONSE;

                    when others =>
                        flow_state <= ST_RESET;
                end case;
            end if;
        end if;
    end process;

end Behavioral;