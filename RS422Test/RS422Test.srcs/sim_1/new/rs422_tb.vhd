library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity rs422_tb is
end rs422_tb;

architecture Behavioral of rs422_tb is

    constant CLK_PERIOD : time := 20 ns;

    signal clk    : std_logic := '0';
    signal rx     : std_logic := '1';
    signal tx     : std_logic;
    signal tx_en  : std_logic;
    signal tx_nen : std_logic;

begin

    dut : entity work.rs422
        port map (
            CLK    => clk,
            RX     => rx,
            TX     => tx,
            TX_EN  => tx_en,
            TX_nEN => tx_nen
        );

    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    stim_process : process
    begin
        rx <= '1';

        wait for 2 us;
        assert tx_en = '1'
            report "TX_EN should be active high"
            severity failure;

        assert tx_nen = '0'
            report "TX_nEN should be active low"
            severity failure;

        assert tx = '1'
            report "TX should be idle high before transmission"
            severity failure;

        wait for 1 sec + 10 us;
        assert tx = '0'
            report "Expected start bit after the initial delay"
            severity failure;

        wait for 20 us;
        assert tx = '1'
            report "Expected first data bit to be logic 1 for ASCII 'A'"
            severity failure;

        report "RS422 testbench completed successfully";
        wait;
    end process;

end Behavioral;
