library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rs422_dock is
-- Testbenches do not have ports
end tb_rs422_dock;

architecture sim of tb_rs422_dock is

    -- ==========================================
    -- COMPONENT DECLARATION
    -- ==========================================
    component rs422_dock
        Port ( FPGA_CLK_50MHZ   : in STD_LOGIC;
               RESET_SW         : in STD_LOGIC;
               RS422_TX         : out STD_LOGIC;
               RS422_RX         : in STD_LOGIC;
               RS422_TX_EN      : out STD_LOGIC;
               RS422_TX_nEN     : out STD_LOGIC;
               FP_STS1_GREEN    : out STD_LOGIC;
               FP_STS2_YELLOW   : out STD_LOGIC;
               F_nLOE           : out STD_LOGIC_VECTOR (9 downto 0);
               F_LE             : out STD_LOGIC_VECTOR (9 downto 0);
               F1_LD            : out STD_LOGIC_VECTOR (15 downto 0);
               F2_LD            : out STD_LOGIC_VECTOR (15 downto 0);
               F3_LD            : out STD_LOGIC_VECTOR (15 downto 0);
               TP_CLK_TST       : out STD_LOGIC);
    end component;

    -- ==========================================
    -- SIGNALS
    -- ==========================================
    -- Inputs to UUT 
    signal clk          : std_logic := '0';
    signal reset        : std_logic := '0'; -- Starts active-low (pressed)
    signal rx_in        : std_logic := '1'; -- UART idles high

    -- Outputs from UUT
    signal tx_out       : std_logic;
    signal tx_en        : std_logic;
    signal tx_nen       : std_logic;
    signal led_green    : std_logic;
    signal led_yellow   : std_logic;
    signal f_nloe       : std_logic_vector(9 downto 0);
    signal f_le         : std_logic_vector(9 downto 0);
    signal f1_ld        : std_logic_vector(15 downto 0);
    signal f2_ld        : std_logic_vector(15 downto 0);
    signal f3_ld        : std_logic_vector(15 downto 0);
    signal tp_clk       : std_logic;

    -- Timing constants
    constant clk_period : time := 20 ns;      -- 50 MHz clock
    constant bit_period : time := 104167 ns;  -- 9600 Baud (1 sec / 9600)

begin

    -- ==========================================
    -- INSTANTIATE UUT
    -- ==========================================
    uut: rs422_dock PORT MAP (
        FPGA_CLK_50MHZ => clk,
        RESET_SW       => reset,
        RS422_TX       => tx_out,
        RS422_RX       => rx_in,
        RS422_TX_EN    => tx_en,
        RS422_TX_nEN   => tx_nen,
        FP_STS1_GREEN  => led_green,
        FP_STS2_YELLOW => led_yellow,
        F_nLOE         => f_nloe,
        F_LE           => f_le,
        F1_LD          => f1_ld,
        F2_LD          => f2_ld,
        F3_LD          => f3_ld,
        TP_CLK_TST     => tp_clk
    );

    -- ==========================================
    -- CLOCK GENERATION PROCESS
    -- ==========================================
    clk_process : process
    begin
        clk <= '0';
        wait for clk_period / 2;
        clk <= '1';
        wait for clk_period / 2;
    end process;

    -- ==========================================
    -- STIMULUS PROCESS
    -- ==========================================
    stim_proc: process
        -- Helper procedure to simulate PC sending a byte to the FPGA at 9600 baud
        procedure send_rx_byte(data : std_logic_vector(7 downto 0)) is
        begin
            -- Send Start Bit (Low)
            rx_in <= '0';
            wait for bit_period;
            
            -- Send 8 Data Bits (LSB First)
            for i in 0 to 7 loop
                rx_in <= data(i);
                wait for bit_period;
            end loop;
            
            -- Send Stop Bit (High)
            rx_in <= '1';
            wait for bit_period;
        end procedure;

    begin
        -- 1. Hold reset state (active low) for 100 ns
        wait for 100 ns;
        reset <= '1'; -- Release reset

        -- 2. Wait for the FPGA to finish its BOOT_INIT sequence
        -- The FSM will immediately write 0s to the hardware to set 511.5 ohms.
        wait for 2 ms;

        -- 3. Simulate PC sending the 4-byte target command: 
        -- WRITE (0x55), CH11 (0x0B), DATA MSB (0x03), DATA LSB (0xFF)
        
        send_rx_byte(x"55"); -- Byte 1: Write command
        wait for 500 us;     -- Small inter-byte delay
        
        send_rx_byte(x"0B"); -- Byte 2: Channel 11
        wait for 500 us;
        
        send_rx_byte(x"03"); -- Byte 3: High byte of 1023 resistance code
        wait for 500 us;
        
        send_rx_byte(x"FF"); -- Byte 4: Low byte of 1023 resistance code
        
        -- 4. Wait and observe the physical latch update sequence & TX Echo
        -- Sending 4 bytes back via TX takes ~4.16 ms at 9600 baud.
        wait for 10 ms;

        -- 5. Suspend simulation
        wait;
    end process;

end sim;