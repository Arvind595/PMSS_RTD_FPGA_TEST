----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 08/06/2026 09:01:01 PM
-- Design Name: 
-- Module Name: fpga_test - Behavioral
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

entity fpga_test is
    Port ( clk_main : in STD_LOGIC;
           clk_out : out STD_LOGIC;
           sts_led1 : out STD_LOGIC;
           sts_led2 : out STD_LOGIC);
end fpga_test;

architecture Behavioral of fpga_test is

begin

    high_speed_clk : process(clk_main)

end Behavioral;
