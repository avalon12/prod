/*
 * Copyright (c) 2008-2012, SOWNet Technologies B.V.
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
*/

/**
 * Provides a software implementation of the SPI protocol for use on MSP430 processors
 * that do not have a hardware SPI bus.
 * 
 * Provides normal read/write SpiByte, as well as faster read-only/write-only versions that
 * save cycles by ignoring output and input, respectively. 
 */
module HplChipconSoftwareSpiP {
	provides {
		interface Init;
		interface SpiByte;
		interface SpiByte as WriteOnly;
		interface SpiByte as ReadOnly;
		interface SpiPacket;
	}
	
	uses {
		interface GeneralIO as MOSI;
		interface GeneralIO as MISO;
		interface GeneralIO as Clock;
	}
}

implementation {
	
	enum {
		B0 = 1 << 0,
		B1 = 1 << 1,
		B2 = 1 << 2,
		B3 = 1 << 3,
		B4 = 1 << 4,
		B5 = 1 << 5,
		B6 = 1 << 6,
		B7 = 1 << 7,
	};
	
	bool owned = FALSE;
	bool busy = FALSE;
	
	// these are protected by the busy flag
	norace uint8_t* txBuffer;
	norace uint8_t* rxBuffer;
	norace uint16_t length;
	norace uint16_t count;
	
	/**
	 * Initialise I/O pins.
	 */
	command error_t Init.init() {
		call MISO.makeInput();
		call MOSI.makeOutput();
		call Clock.makeOutput();
		call Clock.clr();
		return SUCCESS;
	}
	
	/**
	 * Send/receive a single bit.
	 */
	inline uint8_t sendBit(uint8_t bit) {
		// data is read on the rising edge
		
		// falling edge
		call Clock.clr();
		
		// wiggle wiggle
		if (bit) {
			call MOSI.set();
		} else {
			call MOSI.clr();
		}
		
		// rising edge
		call Clock.set();
		
		return call MISO.get();
	}
	
	/**
	 * Synchronous transmit and receive (can be in interrupt context)
	 * @param tx Byte to transmit
	 * @return the received byte
	 */
	async command uint8_t SpiByte.write(uint8_t tx) {
		uint8_t rx = 0;
		
		// shifts are slow, x << n is generated by shifting by one, n times
		// also, putting this in an atomic block means all the atomics in GpIO.set()/clr()
		// get collapsed into it, resulting in fully inlined assembler (checked with objdump)
		atomic {
			rx |= sendBit(tx & B7); rx <<= 1;
			rx |= sendBit(tx & B6); rx <<= 1;
			rx |= sendBit(tx & B5); rx <<= 1;
			rx |= sendBit(tx & B4); rx <<= 1;
			rx |= sendBit(tx & B3); rx <<= 1;
			rx |= sendBit(tx & B2); rx <<= 1;
			rx |= sendBit(tx & B1); rx <<= 1;
			rx |= sendBit(tx & B0); // don't shift after the last bit
			call Clock.clr();			// idle low
		}

		return rx;
	}
	
	/**
	 * Faster, write only version of SpiByte.write(). Saves cycles by not reading the MISO pin
	 * and always returning 0.
	 * @param tx Byte to transmit
	 * @return 0
	 */
	async command uint8_t WriteOnly.write(uint8_t tx) {
		// putting this in an atomic block means all the atomics in GpIO.set()/clr()
		// get collapsed into it, resulting in fully inlined assembler (checked with objdump)
		
		// falling edge, bit wiggle, rising edge
		#define WRITE_BIT(x) call Clock.clr(); if (x) call MOSI.set(); else call MOSI.clr(); call Clock.set()
		
		atomic {
			WRITE_BIT(tx & B7);
			WRITE_BIT(tx & B6);
			WRITE_BIT(tx & B5);
			WRITE_BIT(tx & B4);
			WRITE_BIT(tx & B3);
			WRITE_BIT(tx & B2);
			WRITE_BIT(tx & B1);
			WRITE_BIT(tx & B0);
			call Clock.clr();
		}

		return 0;
	}
	
	/**
	 * Faster, read only version of SpiByte.read(). Saves cycles by not toggling the output pin.
	 * @param tx ignored
	 * @return the received byte
	 */
	async command uint8_t ReadOnly.write(uint8_t tx) {
		uint8_t rx = 0;
		
		// shifts are slow, x << n is generated by shifting by one, n times
		// also, putting this in an atomic block means all the atomics in GpIO.set()/clr()
		// get collapsed into it, resulting in fully inlined assembler (checked with objdump)
		
		// falling edge, rising edge, read bit into x
		#define READ_BIT(x) call Clock.clr(); call Clock.set(); x |= call MISO.get()
		
		atomic {
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); rx <<= 1;
			READ_BIT(rx); // don't shift after the last bit
			call Clock.clr();
		}

		return rx;
	}
	
	/**
	 * Process /length/ bytes, one byte per run.
	 */
	task void send() {
		uint8_t received = call SpiByte.write(txBuffer == NULL ? 0 : txBuffer[count]);
		if (rxBuffer != NULL) rxBuffer[count] = received;
		count++;
		
		if (count < length) {
			post send();
		} else {
			// we release the busy flag before signalling, so copy the pointers
			uint8_t* tx = txBuffer;
			uint8_t* rx = rxBuffer;
			atomic busy = FALSE;
			
			signal SpiPacket.sendDone(tx, rx, length, SUCCESS);
		}
	}
	
	/**
	 * Send a message over the SPI bus.
	*
	 * @param txBuf A pointer to the buffer to send over the bus. If this
	 *              parameter is NULL, then the SPI will send zeroes.
	 * @param rxBuf A pointer to the buffer where received data should
	 *              be stored. If this parameter is NULL, then the SPI will
	 *              discard incoming bytes.
	 * @param len   Length of the message.  Note that non-NULL rxBuf and txBuf
	 *              parameters must be AT LEAST as large as len, or the SPI
	 *              will overflow a buffer.
	 *
	 * @return SUCCESS if the request was accepted for transfer
	 */
	async command error_t SpiPacket.send(uint8_t* txBuf, uint8_t* rxBuf, uint16_t len) {
		atomic {
			if (busy) return EBUSY;
			busy = TRUE;
		}
		
		txBuffer = txBuf;
		rxBuffer = rxBuf;
		length = len;
		count = 0;
		
		post send();
		return SUCCESS;
	}
	
	default async event void SpiPacket.sendDone(uint8_t* txBuf, uint8_t* rxBuf, uint16_t len, error_t error) {}
	
}
