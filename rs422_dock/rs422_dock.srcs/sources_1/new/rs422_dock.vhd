----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 08.08.2026 19:02:49
-- Design Name: 
-- Module Name: rs422_dock - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity rs422_dock is
    Port ( FPGA_CLK_50MHZ 	: in STD_LOGIC;							--main clock source
           RESET_SW 		: in STD_LOGIC;							--on board reset button  Active Low
           RS422_TX 		: out STD_LOGIC;						--RS422 TX line
           RS422_RX 		: in STD_LOGIC;							--RS422 RX line
           RS422_TX_EN 		: out STD_LOGIC;						--TX Driver Enable active high for transmission
           RS422_TX_nEN 	: out STD_LOGIC;						--TX Driver Enable active Low for transmission
           FP_STS1_GREEN 	: out STD_LOGIC;						--on board Status LED Green
           FP_STS2_YELLOW 	: out STD_LOGIC;						--on board Status LED Yelow
           F_nLOE 			: out STD_LOGIC_VECTOR (9 downto 0);	--Latch Output Enable, to make internal content enable ouside to pin Active Low
           F_LE 			: out STD_LOGIC_VECTOR (9 downto 0);	--Latch enable to latch the incoming data to internal storage  Active high
           F1_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F1/Bus1 for Latch Data
           F2_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F2/Bus2 For Latch Data
           F3_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F3/Bus3 For Latch Data
           --ID 			: in STD_LOGIC_VECTOR (3 downto 0);		--On board DIP switch for Board identification
           TP_CLK_TST 		: out STD_LOGIC						    --test pin output for routing internal clock to outside
           --RESET_PC 		: in STD_LOGIC                          --External Reset signal from master card   Active low
		   );						
end rs422_dock;

architecture Behavioral of rs422_dock is

    -- ==========================================
    -- CONSTANTS
    -- ==========================================
    constant CLK_FREQ       : integer := 50000000;  -- 50 MHz
    constant BAUD_RATE      : integer := 9600;
    constant BAUD_TICKS     : integer := CLK_FREQ / BAUD_RATE; -- 5208
    constant HALF_BAUD      : integer := BAUD_TICKS / 2;       -- 2604
    constant HEART_TICKS    : integer := CLK_FREQ / 2;         -- 1Hz toggle

    -- ==========================================
    -- SIGNALS
    -- ==========================================
    -- Clocks & Heartbeat
    signal heart_cnt        : integer range 0 to HEART_TICKS := 0;
    signal led_green_reg    : std_logic := '0';
    signal baud_cnt         : integer range 0 to BAUD_TICKS := 0;
    signal baud_tick        : std_logic := '0';

    -- Shadow Register (160 bits for all 10 Latches / 16 Channels)
    -- Initialized to all '0's (All relays OFF = 511.5 Ohms per channel)
    signal shadow           : std_logic_vector(159 downto 0) := (others => '0');

    -- Latch Data Slices (Step 4 Mapping)
    signal latch1_data      : std_logic_vector(15 downto 0);
    signal latch2_data      : std_logic_vector(15 downto 0);
    signal latch3_data      : std_logic_vector(15 downto 0);
    signal latch4_data      : std_logic_vector(15 downto 0);
    signal latch5_data      : std_logic_vector(15 downto 0);
    signal latch6_data      : std_logic_vector(15 downto 0);
    signal latch7_data      : std_logic_vector(15 downto 0);
    signal latch8_data      : std_logic_vector(15 downto 0);
    signal latch9_data      : std_logic_vector(15 downto 0);
    signal latch10_data     : std_logic_vector(15 downto 0);

    -- UART RX FSM (4-Byte Payload)
    type rx_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal rx_state         : rx_state_type := IDLE;
    signal rx_bit_cnt       : integer range 0 to 7 := 0;
    signal rx_baud_cnt      : integer range 0 to BAUD_TICKS := 0;
    signal rx_shift_reg     : std_logic_vector(7 downto 0) := (others => '0');
    
    -- RX Command Buffer
    signal rx_byte_idx      : integer range 0 to 3 := 0;
    signal rx_byte_1        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte_2        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte_3        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte_4        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_cmd_ready     : std_logic := '0';

    -- UART TX Low-Level FSM
    type tx_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal tx_state         : tx_state_type := IDLE;
    signal tx_bit_cnt       : integer range 0 to 7 := 0;
    signal tx_data_buf      : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_start         : std_logic := '0';
    signal tx_busy          : std_logic := '0';
    signal tx_reg           : std_logic := '1';
    signal tx_en_reg        : std_logic := '0';

    -- Command Processing & Hardware Update FSM
    type cmd_fsm_type is (
        BOOT_INIT, WAIT_CMD, 
        LATCH_STEP_1, LATCH_STEP_2, LATCH_STEP_3, LATCH_STEP_4, LATCH_STEP_WAIT,
        ACK_BYTE_1, ACK_BYTE_2, ACK_BYTE_3, ACK_BYTE_4, ACK_WAIT
    );
    signal cmd_fsm          : cmd_fsm_type := BOOT_INIT;
    --signal wait_timer       : integer range 0 to BAUD_TICKS * 2 := 0; -- Small delay counter

    -- Bus Drive Registers
    signal f1_bus_reg       : std_logic_vector(15 downto 0) := (others => '0');
    signal f2_bus_reg       : std_logic_vector(15 downto 0) := (others => '0');
    signal f3_bus_reg       : std_logic_vector(15 downto 0) := (others => '0');
    signal le_reg           : std_logic_vector(9 downto 0)  := (others => '0');

    -- ==========================================
    -- PROCEDURES (Step 3: Shadow Mapping)
    -- ==========================================
    procedure update_channel(
        variable shadow_v : inout std_logic_vector(159 downto 0);
        constant ch       : in integer;
        constant r_code   : in std_logic_vector(9 downto 0)
    ) is
        variable index_v : integer;
    begin
        for bit_num in 0 to 9 loop
            index_v := (9 - bit_num) * 16 + ch;
            shadow_v(index_v) := not r_code(bit_num);
        end loop;
    end procedure;

begin

    -- ==========================================
    -- STEP 4: SHADOW TO LATCHES MAPPING 
    -- ==========================================
    -- Continuous assignments slicing the 160-bit shadow into the 10 latches
    latch1_data  <= shadow(39 downto 32)   & shadow(7 downto 0);
    latch2_data  <= shadow(55 downto 48)   & shadow(23 downto 16);
    latch3_data  <= shadow(31 downto 24)   & shadow(15 downto 8);
    
    latch4_data  <= shadow(87 downto 80)   & shadow(71 downto 64);
    latch5_data  <= shadow(119 downto 112) & shadow(103 downto 96);
    latch6_data  <= shadow(63 downto 56)   & shadow(47 downto 40);
    
    latch7_data  <= shadow(151 downto 144) & shadow(135 downto 128);
    latch8_data  <= shadow(95 downto 88)   & shadow(79 downto 72);
    latch9_data  <= shadow(127 downto 120) & shadow(111 downto 104);
    latch10_data <= shadow(159 downto 152) & shadow(143 downto 136);

    -- ==========================================
    -- 1. CLOCKS & HEARTBEAT
    -- ==========================================
    process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            -- Heartbeat
            if heart_cnt = HEART_TICKS - 1 then
                heart_cnt <= 0;
                led_green_reg <= not led_green_reg;
            else
                heart_cnt <= heart_cnt + 1;
            end if;

            -- Baud Generator
            if baud_cnt = BAUD_TICKS - 1 then
                baud_cnt <= 0;
                baud_tick <= '1';
            else
                baud_cnt <= baud_cnt + 1;
                baud_tick <= '0';
            end if;
        end if;
    end process;

    FP_STS1_GREEN <= led_green_reg;
    TP_CLK_TST    <= baud_tick;
    FP_STS2_YELLOW <= rx_cmd_ready; -- Lights up yellow when command is processing

    -- ==========================================
    -- UART RX PROCESS (Step 1: 4-Byte Payload)
    -- ==========================================
    process(FPGA_CLK_50MHZ, RESET_SW)
    begin
        if RESET_SW = '0' then
            rx_state <= IDLE;
            rx_byte_idx <= 0;
            rx_cmd_ready <= '0';
            -- ADD THESE MISSING RESETS:
            rx_baud_cnt  <= 0;
            rx_bit_cnt   <= 0;
            rx_shift_reg <= (others => '0');
            rx_byte_1    <= (others => '0');
            rx_byte_2    <= (others => '0');
            rx_byte_3    <= (others => '0');
            rx_byte_4    <= (others => '0');
        elsif rising_edge(FPGA_CLK_50MHZ) then
            -- Auto clear the command ready flag once main FSM sees it
            if cmd_fsm /= WAIT_CMD then
                rx_cmd_ready <= '0';
            end if;

            case rx_state is
                when IDLE =>
                    rx_baud_cnt <= 0;
                    if RS422_RX = '0' then 
                        rx_state <= START_BIT;
                    end if;

                when START_BIT =>
                    if rx_baud_cnt = HALF_BAUD - 1 then
                        if RS422_RX = '0' then
                            rx_baud_cnt <= 0;
                            rx_bit_cnt <= 0;
                            rx_state <= DATA_BITS;
                        else
                            rx_state <= IDLE;
                        end if;
                    else
                        rx_baud_cnt <= rx_baud_cnt + 1;
                    end if;

                when DATA_BITS =>
                    if rx_baud_cnt = BAUD_TICKS - 1 then
                        rx_baud_cnt <= 0;
                        rx_shift_reg(rx_bit_cnt) <= RS422_RX;
                        if rx_bit_cnt = 7 then
                            rx_state <= STOP_BIT;
                        else
                            rx_bit_cnt <= rx_bit_cnt + 1;
                        end if;
                    else
                        rx_baud_cnt <= rx_baud_cnt + 1;
                    end if;

                when STOP_BIT =>
                    if rx_baud_cnt = BAUD_TICKS - 1 then
                        -- Route received byte into the 4-byte buffer
                        if rx_byte_idx = 0 then
                            rx_byte_1 <= rx_shift_reg;
                            rx_byte_idx <= 1;
                        elsif rx_byte_idx = 1 then
                            rx_byte_2 <= rx_shift_reg;
                            rx_byte_idx <= 2;
                        elsif rx_byte_idx = 2 then
                            rx_byte_3 <= rx_shift_reg;
                            rx_byte_idx <= 3;
                        elsif rx_byte_idx = 3 then
                            rx_byte_4 <= rx_shift_reg;
                            rx_byte_idx <= 0;
                            rx_cmd_ready <= '1'; -- Full 4-byte command received!
                        end if;
                        rx_state <= IDLE;
                    else
                        rx_baud_cnt <= rx_baud_cnt + 1;
                    end if;
            end case;
        end if;
    end process;

    -- ==========================================
    -- UART TX LOW-LEVEL PROCESS 
    -- ==========================================
    process(FPGA_CLK_50MHZ, RESET_SW)
    begin
        if RESET_SW = '0' then
            tx_state <= IDLE;
            tx_reg <= '1';
            tx_en_reg <= '0';
            tx_busy <= '0';
            -- ADD THESE MISSING RESETS:
            tx_bit_cnt  <= 0;
           
        elsif rising_edge(FPGA_CLK_50MHZ) then
            if baud_tick = '1' then
                case tx_state is
                    when IDLE =>
                        tx_reg <= '1';
                        if tx_start = '1' then
                            tx_en_reg <= '1';
                            tx_busy <= '1';
                            tx_state <= START_BIT;
                        else
                            tx_en_reg <= '0';
                            tx_busy <= '0';
                        end if;
                    when START_BIT =>
                        tx_reg <= '0';
                        tx_bit_cnt <= 0;
                        tx_state <= DATA_BITS;
                    when DATA_BITS =>
                        tx_reg <= tx_data_buf(tx_bit_cnt);
                        if tx_bit_cnt = 7 then
                            tx_state <= STOP_BIT;
                        else
                            tx_bit_cnt <= tx_bit_cnt + 1;
                        end if;
                    when STOP_BIT =>
                        tx_reg <= '1';
                        tx_state <= IDLE;
                end case;
            end if;
        end if;
    end process;

    RS422_TX     <= tx_reg;
    RS422_TX_EN  <= tx_en_reg;
    RS422_TX_nEN <= not tx_en_reg;

    -- ==========================================
    -- MAIN FSM (Step 2, 3, & 5: Process Command, Write Shadow, Drive Buses)
    -- ==========================================
    process(FPGA_CLK_50MHZ, RESET_SW)
        variable shadow_v : std_logic_vector(159 downto 0);
        variable ch_int   : integer range 0 to 15;
    begin
        if RESET_SW = '0' then
            cmd_fsm <= BOOT_INIT;
            shadow <= (others => '0');
            f1_bus_reg <= (others => '0');
            f2_bus_reg <= (others => '0');
            f3_bus_reg <= (others => '0');
            le_reg <= (others => '0');
            tx_start <= '0';
            tx_data_buf <= (others => '0');
        elsif rising_edge(FPGA_CLK_50MHZ) then
            -- Default TX pulse off
            tx_start <= '0';

            case cmd_fsm is
                -- Boot: Write all 0s to Hardware (511.5 ohms default)
                when BOOT_INIT =>
                    shadow <= (others => '0');
                    cmd_fsm <= LATCH_STEP_1;

                -- Wait for 4-byte command from RX
                when WAIT_CMD =>
                    if rx_cmd_ready = '1' then
                        if rx_byte_1 = x"AA" then
                            -- Global Reset Command
                            shadow <= (others => '0');
                            cmd_fsm <= LATCH_STEP_1;
                        elsif rx_byte_1 = x"55" then
                            -- Standard Write Command
                            shadow_v := shadow;
                            ch_int   := to_integer(unsigned(rx_byte_2(3 downto 0)));
                            -- Update the shadow using your provided procedure
                            update_channel(shadow_v, ch_int, rx_byte_3(1 downto 0) & rx_byte_4);
                            shadow   <= shadow_v;
                            cmd_fsm  <= LATCH_STEP_1;
                        end if;
                    end if;

                -- Step 5: Bus Assignment & Sequencing
                when LATCH_STEP_1 =>
                    f1_bus_reg <= latch1_data;
                    f2_bus_reg <= latch4_data;
                    f3_bus_reg <= latch7_data;
                    le_reg     <= "0001001001"; -- Assert Latch 7, 4, 1
                    cmd_fsm    <= LATCH_STEP_2;

                when LATCH_STEP_2 =>
                    f1_bus_reg <= latch2_data;
                    f2_bus_reg <= latch5_data;
                    f3_bus_reg <= latch8_data;
                    le_reg     <= "0010010010"; -- Assert Latch 8, 5, 2
                    cmd_fsm    <= LATCH_STEP_3;

                when LATCH_STEP_3 =>
                    f1_bus_reg <= latch3_data;
                    f2_bus_reg <= latch6_data;
                    f3_bus_reg <= latch9_data;
                    le_reg     <= "0100100100"; -- Assert Latch 9, 6, 3
                    cmd_fsm    <= LATCH_STEP_4;

                when LATCH_STEP_4 =>
                    f1_bus_reg <= (others => '0');
                    f2_bus_reg <= (others => '0');
                    f3_bus_reg <= latch10_data;
                    le_reg     <= "1000000000"; -- Assert Latch 10
                    cmd_fsm    <= LATCH_STEP_WAIT;

                when LATCH_STEP_WAIT =>
                    le_reg     <= (others => '0'); -- De-assert all Latches
                    cmd_fsm    <= ACK_BYTE_1;

                -- Step 2: Acknowledge back to PC
                when ACK_BYTE_1 =>
                    if tx_busy = '0' then
                        tx_data_buf <= rx_byte_1; -- Echo 0x55 or 0xAA
                        tx_start    <= '1';
                        cmd_fsm     <= ACK_BYTE_2;
                    end if;
                
                when ACK_BYTE_2 =>
                    if tx_busy = '0' and tx_start = '0' then
                        tx_data_buf <= rx_byte_2; -- Echo Channel
                        tx_start    <= '1';
                        cmd_fsm     <= ACK_BYTE_3;
                    end if;

                when ACK_BYTE_3 =>
                    if tx_busy = '0' and tx_start = '0' then
                        tx_data_buf <= rx_byte_3; -- Echo MSB
                        tx_start    <= '1';
                        cmd_fsm     <= ACK_BYTE_4;
                    end if;

                when ACK_BYTE_4 =>
                    if tx_busy = '0' and tx_start = '0' then
                        tx_data_buf <= rx_byte_4; -- Echo LSB
                        tx_start    <= '1';
                        cmd_fsm     <= ACK_WAIT;
                    end if;

                when ACK_WAIT =>
                    if tx_busy = '0' and tx_start = '0' then
                        cmd_fsm <= WAIT_CMD; -- Done, wait for next command
                    end if;

            end case;
        end if;
    end process;

    -- ==========================================
    -- HARDWARE PIN CONNECTIONS
    -- ==========================================
    -- Assign internal registers to physical pins
    F1_LD  <= f1_bus_reg;
    F2_LD  <= f2_bus_reg;
    F3_LD  <= f3_bus_reg;
    F_LE   <= le_reg;

    -- Keep Output Enables actively driving at all times (Active Low)
    F_nLOE <= (others => '0'); 

end Behavioral;