//
// Copyright (c) 2016, The Swedish Post and Telecom Authority (PTS) 
// All rights reserved.
// 
// Redistribution and use in source and binary forms, with or without 
// modification, are permitted provided that the following conditions are met:
// 
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
// 
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//
// Author: Rolf Andersson (rolf@mechanicalmen.se)
//
// Design Name: FPGA NTP Server
// Module Name: pp_rx
// Description: Packet processing rx part. Parse received packets
// 

`timescale 1ns / 1ps
`default_nettype none

module pp_rx (
  input  wire         areset,             // async reset
  input  wire         clk,
  input wire [47:0]  my_mac_addr0,
  input wire [47:0]  my_mac_addr1,
  input wire [47:0]  my_mac_addr2,
  input wire [47:0]  my_mac_addr3,
  input wire [31:0]  my_ipv4_addr0,
  input wire [31:0]  my_ipv4_addr1,
  input wire [31:0]  my_ipv4_addr2,
  input wire [31:0]  my_ipv4_addr3,
  input wire [127:0] my_ipv6_addr0,
  input wire [127:0] my_ipv6_addr1,
  input wire [127:0] my_ipv6_addr2,
  input wire [127:0] my_ipv6_addr3,
  // Gen config
  input  wire         ipv4_arp_en,        // Enable ipv4 ARP
  input  wire         ipv4_ntp_en,        // Enable ipv4 NTP
  input  wire         ipv6_nd_en,         // Enable ipv6 ND
  input  wire         ipv6_ntp_en,        // Enable ipv6 NTP
  input  wire         mac_check_en,       // Enable check of our MAC
  input  wire         ip_check_en,        // Enable check of our IP
  input  wire [31:0]  ntp_ofs,            // RX time stamp offset
  // From clock
  input  wire [63:0]  ntp_time,           // NTP time
  // MAC 
  input  wire [7:0]   rx_data_valid,
  input  wire [63:0]  rx_data,
  input  wire         rx_bad_frame,
  input  wire         rx_good_frame, 
  // Key mem                     
  output reg          key_req,
  output wire [31:0]  key_id,
  input wire          key_ack,
  input wire [255:0]  key,
  // tx FIFO 
  input  wire         tx_fifo_full,       // Room in FIFO
  output reg          tx_fifo_wr,         
  output wire [999:0] tx_fifo_data,
  // Status bits
  output reg          sts_ipv4_arp_pass,  // ipv4 arp accepted
  output reg          sts_ipv4_ntp_pass,  // ipv4 ntp accepted
  output reg          sts_ipv6_nd_pass,   // ipv4 nd accepted
  output reg          sts_ipv6_ntp_pass,  // ipv4 ntp accepted
  output reg          sts_ipv4_arp_drop,  // ipv4 arp dropped
  output reg          sts_ipv4_ntp_drop,  // ipv4 ntp dropped
  output reg          sts_ipv4_gen_drop,  // general ipv4 packet dropped
  output reg          sts_ipv6_nd_drop,   // ipv6 nd dropped
  output reg          sts_ipv6_ntp_drop,  // ipv6 ntp dropped
  output reg          sts_ipv6_gen_drop,  // general ipv6 packet dropped
  output reg          sts_eth_gen_drop,   // general ethernet drop
  output reg          sts_bad_mac_drop,   // wrong mac
  output reg          sts_bad_ipv4_nbr,   // wrong ipv4 number
  output reg          sts_bad_ipv6_nbr,   // wrong ipv6 number
  output reg          sts_bad_eth_frame,  // bad eth checksum (problably)
  output reg          sts_tx_blocked,     // tx packed missed because tx is blocked (fifo full)
  output reg          sts_bad_md5_key,    // Non existing MD5 key
  output reg          sts_bad_sha1_key    // Non existing SHA1 key
);

`include "pp_par.v"

  localparam KEY_VALID = 255;
  localparam KEY_TYPE  = 254;
  localparam SHA1_KEY  = 1;
  localparam MD5_KEY   = 0;

  // Buffers
  reg [47:0]   DST_MAC_rx_buf;      // Destination/our? MAC address
  reg [127:0]  DST_IP_rx_buf;       // Destination/our? Protocol address (IPv4/6)
  reg [47:0]   SRC_MAC_rx_buf;      // Sender HW address  (MAC)
  reg [127:0]  SRC_IP_rx_buf;       // Sender Protocol address (IPv4/6)
  reg [15:0]   SRC_PORT_rx_buf;     // Source port for reply

  // Received NTP Payload for signing etc  
  reg [1:0]    SRC_LI_rx_buf;       // Sender Leap Indicator
  reg [2:0]    SRC_VN_rx_buf;       // Sender NTP Version Number
  reg [2:0]    SRC_MODE_rx_buf;     // Sender Mode
  reg [7:0]    SRC_STRAT_rx_buf;    // Sender Stratum
  reg [7:0]    SRC_POLL_rx_buf;     // Sender POLL 
  reg [7:0]    SRC_PREC_rx_buf;     // Sender Precision
  reg [31:0]   SRC_RDEL_rx_buf;     // Sender Root Delay
  reg [31:0]   SRC_RDISP_rx_buf;    // Sender Root Dispersion
  reg [31:0]   SRC_REFID_rx_buf;    // Sender Reference ID
  reg [63:0]   SRC_REFTS_rx_buf;    // Sender Reference timestamp
  reg [63:0]   SRC_ORGTS_rx_buf;    // Sender Origin timestamp
  reg [63:0]   SRC_RXTS_rx_buf;     // Sender RX timestamp
  reg [63:0]   SRC_TXTS_rx_buf;     // Sender TX timestamp

  reg [31:0]   SRC_KEYID_rx_buf;    // Sender Key ID
  reg [159:0]  SRC_DGST_rx_buf;     // Sender Digest (MAC, Hash, signature etc)

  reg [7:0]    rx_state;
  wire         rx_start;

  reg [63:0]   rx_ntp_time;          // Our Receive time stamp

  reg          tx_arp;               // Xmit IPV4 ARP response
  reg          tx_ntp4;              // Xmit IPV4 NTP respose
  reg          tx_nd;                // Xmit IPV6 ND response
  reg          tx_ntp6;              // Xmit IPV6 NTP response
  reg          tx_md5;               // Xmit MD5 Signed ntp
  reg          tx_sha1;              // Xmit SHA1 signed ntp

  //-------------------------------------------------------------------------------------------------
  // Address selection and decoding
  //   

  wire   mac_match;
  assign mac_match = rx_data[63:16] == my_mac_addr0 || rx_data[63:16] == my_mac_addr1 || rx_data[63:16] == my_mac_addr2 || rx_data[63:16] == my_mac_addr3;
  
  wire   ipv4_match;
  assign ipv4_match = DST_IP_rx_buf[31:0] == my_ipv4_addr0 || DST_IP_rx_buf[31:0] == my_ipv4_addr1 || DST_IP_rx_buf[31:0] == my_ipv4_addr2 || DST_IP_rx_buf[31:0] == my_ipv4_addr3;

  wire   ipv6_match;
  assign ipv6_match = DST_IP_rx_buf == my_ipv6_addr0 || DST_IP_rx_buf == my_ipv6_addr1 || DST_IP_rx_buf == my_ipv6_addr2 || DST_IP_rx_buf == my_ipv6_addr3;

  wire   ipv4_addr_ok;
  assign ipv4_addr_ok = DST_MAC_rx_buf == my_mac_addr0 && DST_IP_rx_buf[31:0] == my_ipv4_addr0 ||
                        DST_MAC_rx_buf == my_mac_addr1 && DST_IP_rx_buf[31:0] == my_ipv4_addr1 || 
                        DST_MAC_rx_buf == my_mac_addr2 && DST_IP_rx_buf[31:0] == my_ipv4_addr2 || 
                        DST_MAC_rx_buf == my_mac_addr3 && DST_IP_rx_buf[31:0] == my_ipv4_addr3;
  wire   ipv6_addr_ok;
  assign ipv6_addr_ok = DST_MAC_rx_buf == my_mac_addr0 && DST_IP_rx_buf == my_ipv6_addr0 ||
                        DST_MAC_rx_buf == my_mac_addr1 && DST_IP_rx_buf == my_ipv6_addr1 || 
                        DST_MAC_rx_buf == my_mac_addr2 && DST_IP_rx_buf == my_ipv6_addr2 || 
                        DST_MAC_rx_buf == my_mac_addr3 && DST_IP_rx_buf == my_ipv6_addr3;

  reg [1:0] mac_addr_sel;
  always @(*) begin
    if (DST_MAC_rx_buf == my_mac_addr0) begin
      mac_addr_sel = 2'b00;
    end else if (DST_MAC_rx_buf == my_mac_addr1) begin
      mac_addr_sel = 2'b01;
    end else if (DST_MAC_rx_buf == my_mac_addr2) begin
      mac_addr_sel = 2'b10;
    end else /*if (DST_MAC_rx_buf == my_mac_addr3)*/ begin
      mac_addr_sel = 2'b11;
    end
  end // always @ reg
  
  reg [1:0] ipv4_addr_sel;
  always @(*) begin
    if (DST_IP_rx_buf[31:0] == my_ipv4_addr0) begin
      ipv4_addr_sel = 2'b00;
    end else if (DST_IP_rx_buf[31:0] == my_ipv4_addr1) begin
      ipv4_addr_sel = 2'b01;
    end else if (DST_IP_rx_buf[31:0] == my_ipv4_addr2) begin
      ipv4_addr_sel = 2'b10;
    end else /*if (DST_IP_rx_buf[31:0] == my_ipv4_addr3)*/ begin
      ipv4_addr_sel = 2'b11;
    end
  end // always @ reg
  
  reg [1:0] ipv6_addr_sel;
  always @(*) begin
    if (DST_IP_rx_buf == my_ipv6_addr0) begin
      ipv6_addr_sel = 2'b00;
    end else if (DST_IP_rx_buf == my_ipv6_addr1) begin
      ipv6_addr_sel = 2'b01;
    end else if (DST_IP_rx_buf == my_ipv6_addr2) begin
      ipv6_addr_sel = 2'b10;
    end else /*if (DST_IP_rx_buf == my_ipv6_addr3)*/ begin
      ipv6_addr_sel = 2'b11;
    end
  end // always @ begin

  //-------------------------------------------------------------------------------------------------
  // Decode start of new packet
  reg [7:0] prev_rx_data_valid;
  always @(posedge clk, posedge areset) begin
    if (areset == 1'b1) begin
      prev_rx_data_valid <= 8'h00;
    end else begin
      prev_rx_data_valid <= rx_data_valid;
    end
  end
  
  assign rx_start = (rx_data_valid == 8'hff && prev_rx_data_valid == 8'h0);

  //-------------------------------------------------------------------------------------------------
  // Decode packet

  always @(posedge clk, posedge areset) begin
    if (areset == 1'b1) begin
      rx_state          <= 'b0;
      tx_fifo_wr        <= 'b0;
      tx_arp            <= 'b0;
      tx_ntp4           <= 'b0;
      tx_nd             <= 'b0;
      tx_ntp6           <= 'b0;
      tx_md5            <= 'b0;
      tx_sha1           <= 'b0;
      key_req           <= 'b0;    
      sts_ipv4_arp_pass <= 'b0;
      sts_ipv4_ntp_pass <= 'b0;
      sts_ipv6_nd_pass  <= 'b0;
      sts_ipv6_ntp_pass <= 'b0;
      sts_ipv4_arp_drop <= 'b0;
      sts_ipv4_ntp_drop <= 'b0;
      sts_ipv4_gen_drop <= 'b0;
      sts_ipv6_nd_drop  <= 'b0;
      sts_ipv6_ntp_drop <= 'b0;
      sts_ipv6_gen_drop <= 'b0;
      sts_bad_mac_drop  <= 'b0;
      sts_eth_gen_drop  <= 'b0;
      sts_bad_ipv4_nbr  <= 'b0;
      sts_bad_ipv6_nbr  <= 'b0;
      sts_bad_eth_frame <= 'b0;
      sts_tx_blocked    <= 'b0;
      sts_bad_md5_key   <= 'b0;
      sts_bad_sha1_key  <= 'b0;
      
    end else begin

      // Defaults
      tx_fifo_wr        <= 'b0;
      key_req           <= 'b0;
      sts_ipv4_arp_pass <= 'b0;
      sts_ipv4_ntp_pass <= 'b0;
      sts_ipv6_nd_pass  <= 'b0;
      sts_ipv6_ntp_pass <= 'b0;
      sts_ipv4_arp_drop <= 'b0;
      sts_ipv4_ntp_drop <= 'b0;
      sts_ipv4_gen_drop <= 'b0;
      sts_ipv4_gen_drop <= 'b0;
      sts_ipv6_nd_drop  <= 'b0;
      sts_ipv6_ntp_drop <= 'b0;
      sts_ipv6_gen_drop <= 'b0;
      sts_bad_mac_drop  <= 'b0;
      sts_eth_gen_drop  <= 'b0;
      sts_bad_ipv4_nbr  <= 'b0;
      sts_bad_ipv6_nbr  <= 'b0;
      sts_bad_eth_frame <= 'b0;
      sts_tx_blocked    <= 'b0;
      sts_bad_md5_key   <= 'b0;
      sts_bad_sha1_key  <= 'b0;

      //-----------------------------------------------------------------------------------------------------------//
      case (rx_state)
        8'h00 : begin

          // Reset some values in a convenient place

          SRC_PORT_rx_buf  <= 'b0;
          SRC_KEYID_rx_buf <= 'b0;
          SRC_DGST_rx_buf  <= 'b0;

          tx_arp  <= 1'b0;
          tx_ntp4 <= 1'b0;
          tx_nd   <= 1'b0;
          tx_ntp6 <= 1'b0;
          tx_md5  <= 1'b0;
          tx_sha1 <= 1'b0;
  
          if (rx_start == 1'b1) begin

            // Stamp our rx time
            rx_ntp_time <= ntp_time + $signed(ntp_ofs) - HW_RX_LAT;

            DST_MAC_rx_buf        <= rx_data[63:16];  // Save destination mac address
            SRC_MAC_rx_buf[47:32] <= rx_data[15:0];   // Save part of sender mac address

            if (rx_data_valid == 8'hff && rx_data[63:16] == BCAST) begin
              // if destination is broadcast check for ARP
              rx_state <= 8'h01;
            end else if (rx_data_valid == 8'hff && rx_data[63:40] == 24'h3333ff) begin
              // if destination is multicast check for Neighbour Solicitation
              rx_state <= 8'h31;
            end else if (rx_data_valid == 8'hff && (mac_match == 1'b1 || mac_check_en == 1'b0)) begin
              // if our mac address check for NTP
              rx_state <= 8'h11;
            end else begin
              rx_state         <= 8'h00;
              sts_bad_mac_drop <= 1'b1;
            end
          end // if (rx_start == 1'b1)

        end

        //-----------------------------------------------------------------------------------------------------------//
        // Broadcast: Check for ARP here
        8'h01 : begin
          SRC_MAC_rx_buf[31:0] <= rx_data[63:32];   // Save rest of sender mac address
          // ARP check ETYPE and HTYPE
          if (rx_data_valid == 8'hff && rx_data[31:16] == ETYPE_ARP && rx_data[15:0] == HTYPE_ETH) begin
            if (ipv4_arp_en == 1'b1) begin
              rx_state = 8'h02;
            end else begin
              rx_state          <= 8'h00;
              sts_ipv4_arp_drop <= 1'b1;
            end
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_gen_drop <= 1'b1;
          end
        end
        // ARP starts here
        8'h02 :
          // check PTYPE, HLEN, PLEN, OPER and that SHA field is same as sender
          if (rx_data_valid == 8'hff && rx_data[63:48] == PTYPE_V4 && rx_data[47:40] == HLEN && rx_data[39:32] == PLEN && 
              rx_data[31:16] == REQ && rx_data[15:0] == SRC_MAC_rx_buf[47:32]) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_arp_drop <= 1'b1;
          end
        8'h03 : begin
          SRC_IP_rx_buf[31:0] <= rx_data[31:0];  // Save sender IP addr
          // Check remaining SHA
          if (rx_data_valid == 8'hff && rx_data[63:32] == SRC_MAC_rx_buf[31:0]) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_arp_drop <= 1'b1;
          end
        end
        8'h04 : begin
          // ignore THA and save dst IP
          DST_IP_rx_buf[31:16] <= rx_data[15:0];
          if (rx_data_valid == 8'hff ) begin
            rx_state <= rx_state + 1; 
          end else begin
            rx_state <= 0;
            sts_ipv4_arp_drop <= 1'b1;
          end
        end
        8'h05 : begin
          // Save rest of my IP
          DST_IP_rx_buf[15:0] <= rx_data[63:48];
          if (rx_data_valid == 8'hff && rx_data[47:0] == 48'h0) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv4_arp_drop <= 1'b1;
            rx_state <= 8'h00;
          end
	end
        8'h06 :
          if (ipv4_match == 1'b0) begin
            sts_bad_ipv4_nbr  <= 1'b1;
            sts_ipv4_arp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end else if (rx_data_valid == 8'hff && rx_data[63:0] == 64'b0) begin
            // Check padding and dst IP
            rx_state <= rx_state + 1; 
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_arp_drop <= 1'b1;
          end
        8'h07, 8'h08 : begin
          // Loop here until status available
          if ((rx_data_valid == 8'h0f && rx_state == 8'h07) || (rx_data_valid == 8'h00 && rx_state == 8'h08)) begin
            // Check ethernet CSUM status
            if (rx_good_frame == 1'b1) begin
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr        <= 1'b1; // OK start tx
                tx_arp            <= 1'b1;
                sts_ipv4_arp_pass <= 1'b1;
              end else begin
                sts_ipv4_arp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv4_arp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              // Wait for status
              rx_state <= 8'h08;
            end
          end else begin // if ((rx_data_valid == 8'h0f && rx_state == 8'h08) || (rx_data_valid == 8'h00 && rx_state == 8'h08))
            // Malformed packet
            sts_ipv4_arp_drop <= 1'b1;
            rx_state <= 8'h00;
          end // else: !if((rx_data_valid == 8'h0f && rx_state == 8'h08) || (rx_data_valid == 8'h00 && rx_state == 8'h08))
        end // case: 8'h07, 8'h08

        //-----------------------------------------------------------------------------------------------------------//
        // IPV6 multicast: check for ND
        8'h31 : begin
          SRC_MAC_rx_buf[31:0] <= rx_data[63:32];   // Save rest of sender mac address
          // ND check ETYPE and HTYPE
          if (rx_data_valid == 8'hff && rx_data[31:16] == ETYPE_V6 && rx_data[15:12] == 4'd6) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state          <= 8'h00;
            sts_eth_gen_drop  <= 1'b1;
          end
        end
        8'h32 : begin
          SRC_IP_rx_buf[127:112] <= rx_data[15:0];  // Save part of sender ip address
          // check Payload length & next head
          if (rx_data_valid == 8'hff && rx_data[47:32] == 16'd32 && rx_data[31:24] == 8'd58) begin
            if (ipv6_nd_en == 1'b1) begin
              // Save part of src ip address
              rx_state <= 8'h33;
            end else begin
              rx_state         <= 8'h00;
              sts_ipv6_nd_drop <= 1'b1;
            end
          end else begin
            rx_state         <= 8'h00;
            sts_ipv6_gen_drop <= 1'b1;
          end
        end
        // IPv6 ND starts here
        8'h33 : begin
          SRC_IP_rx_buf[111:48] <= rx_data[63:0];  // Save part of src addr
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state         <= 8'h00;
            sts_ipv6_nd_drop <= 1'b1;
          end
        end
        8'h34 : begin
          // Save rest of src addr and ignore part of dest IP [127:112]
          SRC_IP_rx_buf[47:0] <= rx_data[63:16];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin 
            rx_state         <= 8'h00;
            sts_ipv6_nd_drop <= 1'b1;
          end
        end
        8'h35 :
          // Ignore more of dest IP [111:48]
          if (rx_data_valid == 8'hff ) begin
            rx_state <= rx_state + 1; 
          end else begin
            rx_state         <= 8'h00;
            sts_ipv6_nd_drop <= 1'b1;
          end
        8'h36 :
          // Ignore rest of dest IP [47:0] and check ns code
          if (rx_data_valid == 8'hff && rx_data[15:8] == 8'd135) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_nd_drop <= 1'b1;
            rx_state         <= 8'h00;
          end
        8'h37 : begin
          // save part of dst IP
          DST_IP_rx_buf[127:112] <= rx_data[15:0];
          // Ignore CSUM (TBD) and reserved".
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_nd_drop <= 1'b1;
            rx_state         <= 8'h00;
          end
        end
        8'h38 : begin
          // save part of DST IP
          DST_IP_rx_buf[111:48] <= rx_data[63:0];
          if (rx_data_valid == 8'hff ) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_nd_drop <= 1'b1;
            rx_state         <= 8'h00;
          end
        end
        8'h39 : begin
          // save rest of dst IP
          DST_IP_rx_buf[47:0] <= rx_data[63:16];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_nd_drop <= 1'b1;
            rx_state         <= 8'h00;
          end 
        end
        8'h3a, 8'h3b : begin
          // Ignore opt part ( src eth mac)
          if (ipv6_match == 1'b0) begin
            sts_bad_ipv6_nbr <= 1'b1;
            sts_ipv6_nd_drop <= 1'b1;
            rx_state         <= 8'h00;
          end if ((rx_data_valid == 8'h3f && rx_state == 8'h3a) || (rx_data_valid == 8'h00 && rx_state == 8'h3b)) begin
            if (rx_good_frame == 1'b1) begin
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr       <= 1'b1; // OK start tx
                tx_nd            <= 1'b1;
                sts_ipv6_nd_pass <= 1'b1;
              end else begin
                sts_ipv6_nd_drop <= 1'b1;
                sts_tx_blocked   <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv6_nd_drop  <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h3b;
            end
          end else begin // if ((rx_data_valid == 8'h3f && rx_state == 8'h3a) || (rx_data_valid == 8'h00 && rx_state == 8'h3b))
            // Malformed packet
            sts_ipv6_nd_drop  <= 1'b1;
            rx_state <= 8'h00;
          end // else: !if((rx_data_valid == 8'h3f && rx_state == 8'h3a) || (rx_data_valid == 8'h00 && rx_state == 8'h3b))
        end // case: 8'h3a, 8'h3b

        //-----------------------------------------------------------------------------------------------------------//
        // MAC address match: packet identification
        8'h11 : begin
           SRC_MAC_rx_buf[31:0] <= rx_data[63:32];   // Save rest of sender mac address
           // check ETYPE and IP Version and header length. Ignore DSCP & ECN 
           if (rx_data_valid == 8'hff && rx_data[31:16] == ETYPE_V4 && rx_data[15:12] == 4'd4 && rx_data[11:8] == 4'd5) begin
             rx_state <= 8'h12;  // goto NTP IPv4
           end else if (rx_data_valid == 8'hff && rx_data[31:16] == ETYPE_V6 && rx_data[15:12] == 4'd6) begin
             rx_state <= 8'h52;  // goto IPv6
           end else if (rx_data_valid == 8'hff && rx_data[31:16] == ETYPE_ARP && rx_data[15:0] == HTYPE_ETH) begin
             if (ipv4_arp_en == 1'b1) begin // Goto ARP
               rx_state <= 8'h02;
             end else begin
               rx_state          <= 8'h00;
               sts_ipv4_arp_drop <= 1'b1;
             end
           end else begin
             rx_state         <= 8'h00;
             sts_eth_gen_drop <= 1'b1;
           end
	end

        //------------------------------------------------------//
        // IPv4 NTP
        8'h12 :
          // check Total length  Ignore ID, check no fragmentation, protocol = UDP
          if (rx_data_valid == 8'hff && (rx_data[63:48] == NTP_IP_LEN || rx_data[63:48] == NTP_IP_MD5_LEN || rx_data[63:48] == NTP_IP_SHA1_LEN) && 
              rx_data[29] == 1'b0 && rx_data[7:0] == PROT_UDP) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_gen_drop <= 1'b1;
          end
        8'h13 : begin
          // Ignore header CSUM, save source IP, save dst IP
          SRC_IP_rx_buf[31:0]  <= rx_data[47:16];
          DST_IP_rx_buf[31:16] <= rx_data[15:0];
          if (rx_data_valid == 8'hff ) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_gen_drop <= 1'b1;
          end
	end
        8'h14 : begin
          DST_IP_rx_buf[15:0] <= rx_data[63:48]; // Save rest of dst address
          SRC_PORT_rx_buf     <= rx_data[47:32]; // Save source port 
          // Decode packet length get signing type
          if (rx_data[15:0] == NTP_UDP_MD5_LEN) begin
            tx_md5 <= 1'b1;
          end
          if (rx_data[15:0] == NTP_UDP_SHA1_LEN) begin
            tx_sha1 <= 1'b1;
          end
          // Check dest port = 123, udp length
          if (rx_data_valid == 8'hff && rx_data[31:16] == 16'd123 &&
              (rx_data[15:0] == NTP_UDP_LEN || rx_data[15:0] == NTP_UDP_MD5_LEN || rx_data[15:0] == NTP_UDP_SHA1_LEN) &&
              ipv4_ntp_en == 1'b1) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end // case: 8'h14
        8'h15 : begin
          // Ignore UDP CSUM, save LI, VN, mode, poll, stratum, precision [23:16] and half root delay [15:0] 
          SRC_LI_rx_buf          <= rx_data[47:46];
          SRC_VN_rx_buf          <= rx_data[45:43];
          SRC_MODE_rx_buf        <= rx_data[42:40];
          SRC_STRAT_rx_buf       <= rx_data[39:32];
          SRC_POLL_rx_buf        <= rx_data[31:24];
          SRC_PREC_rx_buf        <= rx_data[23:16];
          SRC_RDEL_rx_buf[31:16] <= rx_data[15:0];
          // Check IP address and matches with MAC
          if (ip_check_en == 1'b1 && (ipv4_match == 1'b0 || (ipv4_addr_ok == 1'b0 && mac_check_en == 1'b1))) begin
            rx_state          <= 8'h00;
            sts_bad_ipv4_nbr  <= 1'b1;
            sts_ipv4_ntp_drop <= 1'b1;
            // check MODE (client)
	  end else if (rx_data_valid == 8'hff && rx_data[42:40] == 3'd3) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h16 : begin
          // Save half Root Delay [63:48], root disp [47:16], half ref id [15:0]
          SRC_RDEL_rx_buf[15:0]   <= rx_data[63:48];
          SRC_RDISP_rx_buf        <= rx_data[47:16];
          SRC_REFID_rx_buf[31:16] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state  <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h17 : begin
          // Save half ref ID [63:48], part of ref time stamp [47:0]
          SRC_REFID_rx_buf[15:0]  <= rx_data[63:48];
          SRC_REFTS_rx_buf[63:16] <= rx_data[47:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state  <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h18 : begin
          // Save rest of ref time stamp [63:48] and part of orgin time stamp [47:0]
          SRC_REFTS_rx_buf[15:0]  <= rx_data[63:48];
          SRC_ORGTS_rx_buf[63:16] <= rx_data[47:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state  <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h19 : begin
          // Save rest of origin time stamp [63:48] and part of receive time stamp [47:0]
          SRC_ORGTS_rx_buf[15:0] <= rx_data[63:48];
          SRC_RXTS_rx_buf[63:16] <= rx_data[47:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            rx_state  <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h1a : begin
          SRC_RXTS_rx_buf[15:0]  <= rx_data[63:48];
          SRC_TXTS_rx_buf[63:16] <= rx_data[47:0];
          // Save rest of receive timestamp [63:48] and save part of tx timestamp 
          if (rx_data_valid == 8'hff) begin
            rx_state <= 8'h1b;
          end else begin
            rx_state          <= 8'h00;
            sts_ipv4_ntp_drop <= 1'b1;
          end
        end
        8'h1b, 8'h1c : begin
          if (rx_state == 8'h1b) begin
            SRC_TXTS_rx_buf[15:0] <= rx_data[63:48];  // Save rest of tx timestamp
          end
          if (rx_data_valid == 8'hff && (tx_md5 == 1'b1 || tx_sha1 == 1'b1)) begin
            // Save keyid and part of hash
            SRC_KEYID_rx_buf         <= rx_data[47:16];
            SRC_DGST_rx_buf[159:144] <= rx_data[15:0];  
            rx_state                 <= 8'h1d;
            key_req <= 1'b1;
          end else if ((rx_data_valid == 8'h03 && rx_state == 8'h1b) || (rx_data_valid == 8'h00 && rx_state == 8'h1c)) begin
            if (rx_good_frame == 1'b1) begin // No signing: Check CSUM status
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr        <= 1'b1; // OK start tx
                tx_ntp4           <= 1'b1; // OK start tx
                sts_ipv4_ntp_pass <= 1'b1;
              end else begin
                sts_ipv4_ntp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv4_ntp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h1c;
            end
          end else begin // if ((rx_data_valid == 8'h03 && rx_state == 8'h1b) || (rx_data_valid == 8'h00 && rx_state == 8'h1c))
            // Malformed packet
            sts_ipv4_ntp_drop <= 1'b1;
            rx_state <= 8'h00;  
          end // else: !if((rx_data_valid == 8'h03 && rx_state == 8'h1b) || (rx_data_valid == 8'h00 && rx_state == 8'h1c))
        end // case: 8'h1b, 8'h1c
        8'h1d : begin
          SRC_DGST_rx_buf[143:80] <= rx_data[63:0]; // Save more of digest
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            sts_ipv4_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end
        end
        8'h1e, 8'h1f : begin
          // Check if SHA1
          if (rx_data_valid == 8'hff && tx_sha1 == 1'b1) begin
            SRC_DGST_rx_buf[79:16] <= rx_data[63:0];  // Save part of digest
            rx_state               <= 8'h20;
          end else if (((rx_data_valid == 8'h3f && rx_state == 8'h1e) || (rx_data_valid == 8'h00 && rx_state == 8'h1f)) && tx_md5 == 1'b1) begin
            // MD5 ends here
            if (rx_state == 8'h1e) begin
              SRC_DGST_rx_buf[79:32] <= rx_data[63:16];  // Save rest of digest
            end
            if (tx_md5 & (~key[KEY_VALID] | key[KEY_TYPE]) == 1'b1) begin
              sts_bad_md5_key   <= 1'b1;
              sts_ipv4_ntp_drop <= 1'b1;             
              rx_state <= 8'h00;
            end else if (rx_good_frame == 1'b1) begin
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr        <= 1'b1; // OK start tx
                tx_ntp4           <= 1'b1; // OK start tx
              end else begin
                sts_ipv4_ntp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv4_ntp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h1f;
            end
          end else begin // if (((rx_data_valid == 8'h3f && rx_state == 8'h1e) || (rx_data_valid == 8'h00 && rx_state == 8'h1f)) && tx_md5 == 1'b1)
            sts_ipv4_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end // else: !if(((rx_data_valid == 8'h3f && rx_state == 8'h1e) || (rx_data_valid == 8'h00 && rx_state == 8'h1f)) && tx_md5 == 1'b1)
        end // case: 8'h1e, 8'h1f
        8'h20, 8'h21 : begin // SHA1 ends here
          if (rx_state == 8'h20) begin
            SRC_DGST_rx_buf[15:0] <= rx_data[63:48];  // Save rest of digest
          end
          if ((rx_data_valid == 8'h03 && rx_state == 8'h20) || (rx_data_valid == 8'h00 && rx_state == 8'h21)) begin
            if (tx_sha1 & (~key[KEY_VALID] | ~key[KEY_TYPE]) == 1'b1) begin
              sts_bad_sha1_key  <= 1'b1;
              sts_ipv4_ntp_drop <= 1'b1;
              rx_state <= 8'h00;
            end else if (rx_good_frame == 1'b1) begin
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr        <= 1'b1; // OK start tx
                tx_ntp4           <= 1'b1; // OK start tx
              end else begin
                sts_ipv4_ntp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv4_ntp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h21;
            end
          end else begin // if ((rx_data_valid == 8'h03 && rx_state == 8'h20) || (rx_data_valid == 8'h00 && rx_state == 8'h21))
            sts_ipv4_ntp_drop <= 1'b1;
            rx_state <= 8'h00;            
          end // else: !if((rx_data_valid == 8'h03 && rx_state == 8'h20) || (rx_data_valid == 8'h00 && rx_state == 8'h21))
        end // case: 8'h20, 8'h21

        //------------------------------------------------------//
        // IPv6
        8'h52 : begin
          SRC_IP_rx_buf[127:112] <= rx_data[15:0]; // Save part of source ip
          // Decode packet length get signing type
          if (rx_data[47:32] == NTP_UDP_MD5_LEN) begin
            tx_md5 <= 1'b1;
          end
          if (rx_data[47:32] == NTP_UDP_SHA1_LEN) begin
            tx_sha1 <= 1'b1;
          end
          // check Payload length & next head
          if (rx_data_valid == 8'hff && 
              (rx_data[47:32] == NTP_UDP_LEN || rx_data[47:32] == NTP_UDP_MD5_LEN || rx_data[47:32] == NTP_UDP_SHA1_LEN) &&
               rx_data[31:24] == PROT_UDP) begin
            rx_state   <= 8'h53;  // NTP
          end else if (rx_data_valid == 8'hff && rx_data[47:32] == 16'd32 && rx_data[31:24] == 8'd58) begin
            if (ipv6_nd_en == 1'b1) begin
              rx_state <= 8'h23;  // ND
            end else begin
              SRC_IP_rx_buf  <= 128'b0;
              rx_state <= 8'h00;
              sts_ipv6_nd_drop <= 1'b1;
            end
          end else begin
            rx_state   <= 8'h00;
            sts_ipv6_gen_drop <= 1'b1;
          end
        end
        8'h53 : begin
          // Save part of src addr
          SRC_IP_rx_buf[111:48] <= rx_data[63:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            SRC_IP_rx_buf  <= 128'b0;
            rx_state         <= 8'h00;
            sts_ipv6_ntp_drop <= 1'b1;
          end
        end
        8'h54 : begin
          SRC_IP_rx_buf[47:0] <= rx_data[63:16];   // Save rest of src addr
          DST_IP_rx_buf[127:112] <= rx_data[15:0]; // Save part of dest IP
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin 
            rx_state          <= 8'h00;
            sts_ipv6_ntp_drop <= 1'b1;
          end
        end
        8'h55 : begin
          DST_IP_rx_buf[111:48] <= rx_data[63:0]; // Save part of dest IP
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            rx_state          <= 8'h00;
            sts_ipv6_ntp_drop <= 1'b1;
          end
	end
        8'h56 : begin
          DST_IP_rx_buf[47:0] <= rx_data[63:16]; // Save rest of dest IP
          SRC_PORT_rx_buf     <= rx_data[15:0];  // save source port
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h57 : begin
          // ignore csum [31:16], save LI, VN, Mode, stratum
          SRC_LI_rx_buf          <= rx_data[15:14];
          SRC_VN_rx_buf          <= rx_data[13:11];
          SRC_MODE_rx_buf        <= rx_data[10:8];
          SRC_STRAT_rx_buf       <= rx_data[7:0];

          // Check IP address and match with MAC
          if (ip_check_en == 1'b1 && (ipv6_match == 1'b0 || (ipv6_addr_ok == 1'b0 && mac_check_en == 1'b1))) begin
            rx_state          <= 8'h00;
            sts_bad_ipv6_nbr  <= 1'b1;
            sts_ipv6_ntp_drop <= 1'b1;
          // check dst port, udp length, mode
          end else if (rx_data_valid == 8'hff && rx_data[63:48] == 16'd123 &&
		       (rx_data[47:32] == NTP_UDP_LEN  || rx_data[47:32] == NTP_UDP_MD5_LEN || rx_data[47:32] == NTP_UDP_SHA1_LEN) &&
		        ipv6_ntp_en == 1'b1 && rx_data[10:8] == 3'd3) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end        
        8'h58 : begin
          // save Poll, precision, root delay [47:16], half root disp [15:0]
          SRC_POLL_rx_buf         <= rx_data[63:56];
          SRC_PREC_rx_buf         <= rx_data[55:48];
          SRC_RDEL_rx_buf         <= rx_data[47:16];
          SRC_RDISP_rx_buf[31:16] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h59 : begin
          // save half root disp, ref id, part of ref time stamp [15:0]
          SRC_RDISP_rx_buf[15:0]  <= rx_data[63:48];
          SRC_REFID_rx_buf        <= rx_data[47:16];
          SRC_REFTS_rx_buf[63:48] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h5a : begin
          // save rest of ref time stamp, part of origin time stamp
          SRC_REFTS_rx_buf[47:0]  <= rx_data[63:16];
          SRC_ORGTS_rx_buf[63:48] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h5b : begin
          // save part of origin time stamp, part of rx time stamp
          SRC_ORGTS_rx_buf[47:0] <= rx_data[63:16];
          SRC_RXTS_rx_buf[63:48] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h5c : begin
          // save rest of rx time stamp and save part of tx time stamp
          SRC_RXTS_rx_buf[47:0]  <= rx_data[63:16];
          SRC_TXTS_rx_buf[63:48] <= rx_data[15:0];
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1; 
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state          <= 8'h00;
          end
        end
        8'h5d, 8'h5e : begin
          if (rx_state == 8'h5d) begin
            SRC_TXTS_rx_buf[47:0] <= rx_data[63:16];// Save rest of tx timestamp
          end
          if (rx_data_valid == 8'hff && (tx_md5 == 1'b1 || tx_sha1 == 1'b1)) begin
            // Save part of keyid
            SRC_KEYID_rx_buf[31:16] <= rx_data[15:0];
            rx_state                <= 8'h5f;
          end else if ((rx_data_valid == 8'h3f && rx_state == 8'h5d) || (rx_data_valid == 8'h00 && rx_state == 8'h5e)) begin
            if (rx_good_frame == 1'b1) begin // No signing: Check CSUM status
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr        <= 1'b1; // OK start tx
                tx_ntp6           <= 1'b1; // OK start tx
                sts_ipv6_ntp_pass <= 1'b1;
              end else begin
                sts_ipv6_ntp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv6_ntp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h5e;
            end
          end else begin // if ((rx_data_valid == 8'h3f && rx_state == 8'h5d) || (rx_data_valid == 8'h00 && rx_state == 8'h5e))
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end // else: !if((rx_data_valid == 8'h3f && rx_state == 8'h5d) || (rx_data_valid == 8'h00 && rx_state == 8'h5e))
        end // case: 8'h5d, 8'h5e
        8'h5f : begin
          // Save rest of keyid and part of hash
          SRC_KEYID_rx_buf[15:0]   <= rx_data[63:48];
          SRC_DGST_rx_buf[159:112] <= rx_data[47:0]; 
          if (rx_data_valid == 8'hff) begin
            key_req  <= 1'b1;
            rx_state <= rx_state + 1;
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end
        end
        8'h60 : begin
          // Save  part of hash
          SRC_DGST_rx_buf[111:48] <= rx_data[63:0]; 
          if (rx_data_valid == 8'hff) begin
            rx_state <= rx_state + 1;
          end else begin
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end
        end
        8'h61, 8'h62 : begin
          if (rx_state == 8'h61) begin
            // Save rest of hash
            if (tx_sha1 == 1'b1) begin
              SRC_DGST_rx_buf[47:0]  <= rx_data[63:16];
            end else begin
              SRC_DGST_rx_buf[47:32] <= rx_data[63:48];
            end
          end
          if ((((rx_data_valid == 8'h3f && tx_sha1 == 1'b1) || (rx_data_valid == 8'h03 && tx_md5 == 1'b1)) && rx_state == 8'h61) || (rx_data_valid == 8'h00 && rx_state == 8'h62)) begin
            if (tx_md5 & (~key[KEY_VALID] | key[KEY_TYPE]) == 1'b1) begin // Check that key exist and is compatible
              sts_bad_md5_key   <= 1'b1;
              sts_ipv6_ntp_drop <= 1'b1;
              rx_state <= 8'h00;
            end else if (tx_sha1 & (~key[KEY_VALID] | ~key[KEY_TYPE]) == 1'b1) begin
              sts_bad_sha1_key  <= 1'b1;
              sts_ipv6_ntp_drop <= 1'b1;
              rx_state <= 8'h00;
            end else if (rx_good_frame == 1'b1) begin
              if (tx_fifo_full == 1'b0) begin
                tx_fifo_wr <= 1'b1; // OK start tx
                tx_ntp6    <= 1'b1; // OK start tx
              end else begin
                sts_ipv6_ntp_drop <= 1'b1;
                sts_tx_blocked    <= 1'b1;
              end
              rx_state <= 8'h00;
            end else if (rx_bad_frame == 1'b1) begin
              sts_ipv6_ntp_drop <= 1'b1;
              sts_bad_eth_frame <= 1'b1;
              rx_state <= 8'h00;
            end else begin
              rx_state <= 8'h62;  // Loop until status available
            end
          end else begin // if ((((rx_data_valid == 8'h3f && tx_sha1 == 1'b1) || (rx_data_valid == 8'h03 && tx_md5 == 1'b1)) && rx_state == 8'h61) || (rx_data_valid == 8'h00 && rx_state == 8'h62))
            sts_ipv6_ntp_drop <= 1'b1;
            rx_state <= 8'h00;
          end // else: !if((((rx_data_valid == 8'h3f && tx_sha1 == 1'b1) || (rx_data_valid == 8'h03 && tx_md5 == 1'b1)) && rx_state == 8'h61) || (rx_data_valid == 8'h00 && rx_state == 8'h62))
        end // case: 8'h61, 8'h62
        
        default : begin
          tx_fifo_wr <= 1'b0;
          rx_state   <= 8'h00;
        end
      endcase // case (rx_counter)

    end // else: !if(areset == 1'b1)
    
  end // always @ (posedge clk, posedge areset)

  //----------------------------------------------------------------------------------------------------------------------
				     
  assign key_id = SRC_KEYID_rx_buf;

  // Save some bits by coding address bits into selector
  wire [1:0] my_addr_sel;
  assign my_addr_sel = ((tx_arp | tx_ntp4) == 1'b1) ? ipv4_addr_sel : ipv6_addr_sel;

  assign tx_fifo_data = {rx_ntp_time,
                         my_addr_sel,
                         tx_arp,
                         tx_nd,
                         tx_ntp4,
                         tx_ntp6,
                         tx_md5,
                         tx_sha1,
                         SRC_MAC_rx_buf,
                         SRC_IP_rx_buf, 
                         SRC_PORT_rx_buf,
                         //SRC_PAYLOAD_rx_buf,
                         SRC_LI_rx_buf,
                         SRC_VN_rx_buf,
                         SRC_MODE_rx_buf,
                         SRC_STRAT_rx_buf,
                         SRC_POLL_rx_buf,
                         SRC_PREC_rx_buf,
                         SRC_RDEL_rx_buf,
                         SRC_RDISP_rx_buf,
                         SRC_REFID_rx_buf,
                         SRC_REFTS_rx_buf,
                         SRC_ORGTS_rx_buf,
                         SRC_RXTS_rx_buf,
                         SRC_TXTS_rx_buf,
                         //
                         SRC_KEYID_rx_buf,
                         SRC_DGST_rx_buf,
                         key[159:0]
                        };
endmodule //

`default_nettype wire
