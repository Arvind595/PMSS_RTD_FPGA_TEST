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
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity rs422_dock is
    Port ( FPGA_CLK_50MHZ 	: in STD_LOGIC;							--main clock source
           RESET_SW 		: in STD_LOGIC;							--on board reset button
           RS422_TX 		: out STD_LOGIC;						--RS422 TX line
           RS422_RX 		: in STD_LOGIC;							--RS422 RX line
           RS422_TX_EN 		: out STD_LOGIC;						--TX Driver Enable active high for transmission
           RS422_TX_nEN 	: out STD_LOGIC;						--TX Driver Enable active Low for transmission
           FP_STS1_GREEN 	: out STD_LOGIC;						--on board Status LED Green
           FP_STS2_YELLOW 	: out STD_LOGIC;						--on board Status LED Yelow
           F_nLOE 			: out STD_LOGIC_VECTOR (9 downto 0);	--Latch Output Enable, to make internal content enable ouside to pin	
           F_nLE 			: out STD_LOGIC_VECTOR (9 downto 0);	--Latch enable to latch the incoming data to internal storage
           F1_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F1/Bus1 for Latch Data
           F2_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F2/Bus2 For Latch Data
           F3_LD 			: out STD_LOGIC_VECTOR (15 downto 0);	--F3/Bus3 For Latch Data
           --ID 				: in STD_LOGIC_VECTOR (3 downto 0);		--On board DIP switch for Board identification
           TP_CLK_TST 		: out STD_LOGIC						--test pin output for routing internal clock to outside
           --RESET_PC 		: in STD_LOGIC
		   );						--External Reset signal from master card
end rs422_dock;

architecture Behavioral of rs422_dock is

    -- ==========================================
    -- CONSTANTS
    -- ==========================================
    constant CLK_FREQ       : integer := 50000000; -- 50 MHz
    constant BAUD_RATE      : integer := 9600;
    constant BAUD_TICKS     : integer := CLK_FREQ / BAUD_RATE;       -- 5208
    constant HALF_BAUD      : integer := BAUD_TICKS / 2;             -- 2604
    constant HEART_TICKS    : integer := CLK_FREQ / 2;               -- 25000000 for 1Hz toggle

    -- ==========================================
    -- SIGNALS
    -- ==========================================
    -- Heartbeat
    signal heart_cnt        : integer range 0 to HEART_TICKS := 0;
    signal led_green_reg    : std_logic := '0';

    -- Baud Rate Generator
    signal baud_cnt         : integer range 0 to BAUD_TICKS := 0;
    signal baud_tick        : std_logic := '0';

    -- UART TX FSM
    type tx_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal tx_state         : tx_state_type := IDLE;
    signal tx_bit_cnt       : integer range 0 to 7 := 0;
    signal tx_data          : std_logic_vector(7 downto 0) := x"41"; -- ASCII 'A'
    signal boot_msg_sent    : std_logic := '0';                      -- Tracks if 'A' was sent on boot
    signal tx_reg           : std_logic := '1';                      -- Line idles high
    signal tx_en_reg        : std_logic := '0';

    -- UART RX FSM & Register 1
    type rx_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal rx_state         : rx_state_type := IDLE;
    signal rx_bit_cnt       : integer range 0 to 7 := 0;
    signal rx_baud_cnt      : integer range 0 to BAUD_TICKS := 0;
    signal rx_shift_reg     : std_logic_vector(7 downto 0) := (others => '0');
    signal register_1       : std_logic_vector(7 downto 0) := (others => '0'); 

begin

    -- ==========================================
    -- 1. HEARTBEAT GENERATOR (1Hz Green LED)
    -- ==========================================
    process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            if heart_cnt = HEART_TICKS - 1 then
                heart_cnt <= 0;
                led_green_reg <= not led_green_reg;
            else
                heart_cnt <= heart_cnt + 1;
            end if;
        end if;
    end process;

    FP_STS1_GREEN <= led_green_reg;

    -- ==========================================
    -- 2 & 3. BAUD RATE GENERATOR & TEST PIN
    -- ==========================================
    process(FPGA_CLK_50MHZ)
    begin
        if rising_edge(FPGA_CLK_50MHZ) then
            if baud_cnt = BAUD_TICKS - 1 then
                baud_cnt <= 0;
                baud_tick <= '1';
            else
                baud_cnt <= baud_cnt + 1;
                baud_tick <= '0';
            end if;
        end if;
    end process;

    TP_CLK_TST <= baud_tick; -- Route to test pin

    -- ==========================================
    -- 4. UART TX (Boot message 'A' & Driver Control)
    -- ==========================================
    process(FPGA_CLK_50MHZ, RESET_SW)
    begin
        if RESET_SW = '1' then
            tx_state <= IDLE;
            boot_msg_sent <= '0';
            tx_reg <= '1';
            tx_en_reg <= '0';
        elsif rising_edge(FPGA_CLK_50MHZ) then
            if baud_tick = '1' then
                case tx_state is
                    when IDLE =>
                        tx_reg <= '1';
                        if boot_msg_sent = '0' then
                            tx_en_reg <= '1';        -- Enable RS422 driver
                            tx_state <= START_BIT;
                            boot_msg_sent <= '1';    -- Mark boot message as handled
                        else
                            tx_en_reg <= '0';        -- Disable RS422 driver when idle
                        end if;

                    when START_BIT =>
                        tx_reg <= '0';
                        tx_bit_cnt <= 0;
                        tx_state <= DATA_BITS;

                    when DATA_BITS =>
                        tx_reg <= tx_data(tx_bit_cnt);
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
    -- 5 & 6. UART RX & REGISTER 1
    -- ==========================================
    process(FPGA_CLK_50MHZ, RESET_SW)
    begin
        if RESET_SW = '1' then
            rx_state <= IDLE;
            register_1 <= (others => '0');
        elsif rising_edge(FPGA_CLK_50MHZ) then
            case rx_state is
                when IDLE =>
                    rx_baud_cnt <= 0;
                    if RS422_RX = '0' then -- Start bit detected
                        rx_state <= START_BIT;
                    end if;

                when START_BIT =>
                    if rx_baud_cnt = HALF_BAUD - 1 then
                        if RS422_RX = '0' then -- Confirm still low
                            rx_baud_cnt <= 0;
                            rx_bit_cnt <= 0;
                            rx_state <= DATA_BITS;
                        else
                            rx_state <= IDLE; -- False alarm
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
                        register_1 <= rx_shift_reg; -- 6. Store to register 1
                        rx_state <= IDLE;
                    else
                        rx_baud_cnt <= rx_baud_cnt + 1;
                    end if;
            end case;
        end if;
    end process;

    -- ==========================================
    -- 7 & 8. IGNORE UNUSED PINS / COMMAND ROUTING
    -- ==========================================
    -- Tying unused outputs to safe default states to prevent synthesis warnings
    FP_STS2_YELLOW <= '0';
    F_nLOE         <= (others => '1'); -- Assuming active low output enable
    F_nLE          <= (others => '1'); -- Assuming active low latch enable
    F1_LD          <= (others => 'Z');
    F2_LD          <= (others => 'Z');
    F3_LD          <= (others => 'Z');

end Behavioral;
