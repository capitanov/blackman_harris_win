-------------------------------------------------------------------------------
--
-- Title       : taylor_sincos
-- Design      : Blackman-Harris Windows
-- Author      : Kapitanov Alexander
-- Company     : 
-- E-mail      : sallador@bk.ru
--
-- Description : Sine & Cosine generator by using Taylor function.
--   
--   Input signal of sine/cosine is placed into ROM (or Look-up Table). 
--   You can configure DATA WIDTH and PHASE WIDTH,
--   Also you can set the order of Taylor series: 1 or 2.
--   Data values is signed integer type [DATA_WIDTH-1 : 0]
--   Phase values is signed integer type [PHASE_WIDTH : 0]
--   Look-up table for sine and cosine has LUT_SIZE parameter of ROM depth.
--
--   Parameters:
--
--   DATA_WIDTH   - Number of bits in sin/cos
--   PHASE_WIDT   - Number of bits in phase accumulator
--   LUT_SIZE     - ROM depth for sin/cos (common depth is from 8 to 10)
--   TAY_ORDER	  - Taylor series order: 1 or 2	
--
--   Total delay datapath:
--     IF (PHASE_WIDTH - LUT_SIZE < 2) THEN delay = 5 taps,
--     ELSE
--       IF (DATA_WIDTH < 19) THEN delay = 8 taps.
--       else delay = 11 taps.
--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--
--	GNU GENERAL PUBLIC LICENSE
--  Version 3, 29 June 2007
--
--	Copyright (c) 2018 Kapitanov Alexander
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
--  THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY
--  APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT 
--  HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY 
--  OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, 
--  THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR 
--  PURPOSE.  THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM 
--  IS WITH YOU.  SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF 
--  ALL NECESSARY SERVICING, REPAIR OR CORRECTION. 
-- 
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_signed.all;
use ieee.std_logic_arith.all;

use ieee.math_real.all;

entity taylor_sincos is
    generic (
        DATA_WIDTH      : integer:= 32; --! Number of bits in sin/cos 
        PHASE_WIDTH     : integer:= 14; --! Number of bits in phase accumulator
        LUT_SIZE        : integer:= 9; --! ROM depth for sin/cos (must be less than PHASE_WIDTH)
        -- TAY_ORDER       : integer range 1 to 2:=1; -- Taylor series order 1 or 2
        XSERIES         : string:="ULTRA" --! for 6/7 series: "7SERIES"; for ULTRASCALE: "ULTRA";
	);
    port (
		RST             : in std_logic; --! Global reset
		CLK             : in std_logic; --! Rising edge DSP clock
		
		PHI_ENA         : in std_logic; --! Phase valid signal
		OUT_SIN         : out std_logic_vector(DATA_WIDTH-1 downto 0); -- Sine output
		OUT_COS         : out std_logic_vector(DATA_WIDTH-1 downto 0) -- Cosine output
	);
end entity;

architecture taylor_sincos of taylor_sincos is

	---- Constant declaration ----
    constant ROM_DEPTH	: integer := 2**LUT_SIZE;

	---- Create ROM array via HDL-function by using MATH package ----
	type std_array_RxN is array (0 to ROM_DEPTH-1) of std_logic_vector(2*DATA_WIDTH-1 downto 0); 
	
	function rom_calculate(val_size : integer) return std_array_RxN is
		variable pi_new : real:=0.0;
		variable sc_int : std_array_RxN;
		
		variable re_int : integer:=0;
		variable im_int : integer:=0;
	begin
		for ii in 0 to ROM_DEPTH-1 loop
			pi_new := (real(ii) * MATH_PI) / (2.0 * real(ROM_DEPTH));
			
			re_int := INTEGER((2.0**(DATA_WIDTH-1)-1.0) * cos(pi_new));	
			im_int := INTEGER((2.0**(DATA_WIDTH-1)-1.0) * sin(pi_new));

			sc_int(ii)(2*DATA_WIDTH-1 downto 1*DATA_WIDTH) := STD_LOGIC_VECTOR(CONV_SIGNED(im_int, DATA_WIDTH));
			sc_int(ii)(1*DATA_WIDTH-1 downto 0*DATA_WIDTH) := STD_LOGIC_VECTOR(CONV_SIGNED(re_int, DATA_WIDTH));	
		end loop;
		
		return sc_int;		
	end rom_calculate;	
	
	constant ROM_ARRAY : std_array_RxN := rom_calculate(LUT_SIZE);
	
	---- Phase counter and quadrant ----
	signal cnt          : std_logic_vector(PHASE_WIDTH-1 downto 0);
	signal addr         : std_logic_vector(LUT_SIZE-1 downto 0);	
	signal quadrant     : std_logic_vector(1 downto 0);	
	signal selq         : std_logic_vector(1 downto 0);	
	
    ---- Output mem & registers ----
    signal dpo          : std_logic_vector(2*DATA_WIDTH-1 downto 0);
    signal mem_sin      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem_cos      : std_logic_vector(DATA_WIDTH-1 downto 0);

	---- Select RAM type: Distributed or Block ----
	function calc_string(xx : integer) return string is
	begin 
		if (xx < 10) then -- 11 or 12
			return "distributed";
		else
			return "block";
		end if;
	end calc_string;
	
	constant RAMB_TYPE 	: string:=calc_string(LUT_SIZE);
	
    attribute rom_style: string;
    attribute rom_style of dpo : signal is RAMB_TYPE;

begin
	---- Select quadrant ----
	quadrant <= cnt(PHASE_WIDTH-1 downto PHASE_WIDTH-2);
	
	---- Phase counter ----
	pr_cnt: process(clk) is
	begin
		if rising_edge(clk) then
			if (rst = '1') then
				cnt	<=	(others	=>	'0');			
			elsif (phi_ena = '1') then
				cnt <= cnt + '1';
			end if;
		end if;
	end process;

	---- Sddress for ROM depends on phase width and lut size -----
	---- Phase width less than lut size ----
	xGEN_LESS: if ((PHASE_WIDTH - LUT_SIZE) < 2) generate	
	begin
		addr(LUT_SIZE-1 downto LUT_SIZE-PHASE_WIDTH+2) <= cnt(PHASE_WIDTH-3 downto 0) when rising_edge(clk);
		addr(LUT_SIZE-PHASE_WIDTH+1 downto 0) <= (others=>'0');
	end generate;	
	
	---- Phase width equal lut size ----
	xGEN_EQ: if ((PHASE_WIDTH - LUT_SIZE) = 2) generate	
	begin
		addr <= cnt(LUT_SIZE-1 downto 0) when rising_edge(clk);
	end generate;		
	---- Phase width more than lut size ----
	xGEN_MORE: if ((PHASE_WIDTH - LUT_SIZE) > 2) generate		
		signal acnt     : std_logic_vector(PHASE_WIDTH-LUT_SIZE-3 downto 0);
		signal tay_dat  : std_logic_vector(2*DATA_WIDTH-1 downto 0);
	
		---- Addition delay for 1-order Taylor series ----
		function find_delay(xx: in integer) return integer is
			variable ret    : integer:=0;
		begin
			if (xx < 19) then
				ret := 5;
			else
				ret := 8;
			end if;
			return ret;
		end;
		constant ADD_DELAY	: integer:=find_delay(DATA_WIDTH);
		
		type std_logic_delN is array (ADD_DELAY downto 0) of std_logic_vector(1 downto 0); 
		signal quad 	: std_logic_delN;	
	
	begin
		addr <= cnt(PHASE_WIDTH-3 downto PHASE_WIDTH-LUT_SIZE-2);-- when rising_edge(clk);
		acnt <= cnt(PHASE_WIDTH-3-LUT_SIZE downto 0);-- when rising_edge(clk);
	
		---- 1st order Taylor scheme ----
		xTAY1: entity work.tay1_order
			generic map (
				DATA_WIDTH  => DATA_WIDTH,
				USE_MLT     => FALSE,
				VAL_SHIFT   => LUT_SIZE,
				XSERIES     => XSERIES,
				STAGE       => PHASE_WIDTH-LUT_SIZE-3
			)
			port map (
				rom_dat		=> dpo,
				rom_cnt		=> acnt,
				
				dsp_dat		=> tay_dat,
				
				clk 		=> clk,
				rst  		=> rst
			);
		
		
		---- 2nd order Taylor scheme ----
		---- *DELETED* ----
		
		mem_sin <= tay_dat(2*DATA_WIDTH-1 downto 1*DATA_WIDTH) when rising_edge(clk);	
		mem_cos <= tay_dat(1*DATA_WIDTH-1 downto 0*DATA_WIDTH) when rising_edge(clk);
		
		quad <= quad(quad'left-1 downto 0) & quadrant when rising_edge(clk);
		selq <= quad(quad'left);
	end generate;
	
	xGEN_OUT: if ((PHASE_WIDTH - LUT_SIZE) <= 2) generate
		type std_logic_delN is array (2 downto 0) of std_logic_vector(1 downto 0); 
		signal quad 	: std_logic_delN;	
	begin	
		mem_sin <= dpo(2*DATA_WIDTH-1 downto 1*DATA_WIDTH) when rising_edge(clk);
		mem_cos <= dpo(1*DATA_WIDTH-1 downto 0*DATA_WIDTH) when rising_edge(clk);
		
		quad <= quad(quad'left-1 downto 0) & quadrant when rising_edge(clk);
		selq <= quad(quad'left);
	end generate;	

	dpo <= ROM_ARRAY(conv_integer(UNSIGNED(addr))) when rising_edge(clk);

	---- Output data ----
	pr_quad: process(clk) is
	begin
		if rising_edge(clk) then
			case selq is
				when "00" => 
					out_sin	<= mem_sin;
					out_cos	<= mem_cos;
				when "01" => 
					out_sin	<= mem_cos;
					out_cos	<= NOT(mem_sin) + '1';
				when "10" => 
					out_sin	<= NOT(mem_sin) + '1';
					out_cos	<= NOT(mem_cos) + '1';
				when others => 
					out_sin	<= NOT(mem_cos) + '1';
					out_cos	<= mem_sin;	
			end case;
		end if;
	end process;

end architecture;