/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Shared definitions for the ATtiny system management MCU used on the
 * Avnet SmartEdge IIoT Gateway.
 *
 * The MCU sits on I2C1 at address 0x33 and provides the hardware watchdog,
 * the front panel LEDs and the factory reset button.  The MFD core driver
 * owns the I2C client; the cell drivers reach it through the callbacks in
 * struct attiny_dev, which they obtain from their parent's driver data.
 */

#ifndef _ATTINY_H
#define _ATTINY_H

#include <linux/i2c.h>
#include <linux/mutex.h>

/* I2C Register Space */
/* ------------------ */
#define I2C_WDT_CMDSTS		0x00	/* Write is CMD, Read is STATUS */
#define I2C_WDT_TIME_IRQ	0x01	/* Counter value for interrupt (seconds) */
#define I2C_WDT_TIME_RST	0x02	/* Counter value for reset (seconds) */
#define I2C_WDT_COUNTER		0x03	/* When WDT reset, counter starts at 0 */

/*
 * LED_STATE: Bits [7:4] = led colour/blink, [6] = blink, [5] = red,
 * [4] = green, Bits [3:0] = led blink rate (valid if bit [6] set),
 * [2:0] = '111' on, '000' off, '001' slow, '010' medium, '011' fast,
 * '100' v.fast
 */
#define I2C_LED_STATE		0x04
#define I2C_LED_DUTY		0x05	/* 0-255 Duty On Time */
#define I2C_RSVD06			0x06
#define I2C_STICKY_BITS		0x07	/* Read events, write '1' to clear */

/* No storage needed for these */
#define I2C_FW_REV			0x0E
#define I2C_HW_REV			0x0F
/* ------------------ */

#define I2C_STICKY_FACTORY_RST_SHORT	(1 << 0) /* Short button press */
#define I2C_STICKY_PWR_LOW_DETECTED		(1 << 2) /* PWR_LOW_N asserted */
#define I2C_STICKY_FACTORY_RST_LONG		(1 << 4) /* Long button press */
#define I2C_STICKY_FACTORY_RST_VLONG	(1 << 5) /* Very long button press */
#define I2C_STICKY_RESET_DETECTED		(1 << 6) /* RST_N released */
#define I2C_STICKY_INVALID				(1 << 7) /* Register not valid */

#define WDT_CMD_START				0xAA
#define WDT_CMD_STOP				0x55
#define WDT_CMD_ENA_RESET			0xCC
#define WDT_CMD_DIS_RESET			0x33
#define WDT_CMD_AFTER_RST_ENA		0xDD
#define WDT_CMD_AFTER_RST_DIS		0x22
#define WDT_CMD_ENA_IRQ				0xBB
#define WDT_CMD_DIS_IRQ				0x44
#define WDT_CMD_RESET				0x01
#define WDT_CMD_CLEAR_TIMEOUT_BITS	0x20

#define WDT_STATUS_RUNNING			(1 << 0)
#define WDT_STATUS_IRQ_ENA			(1 << 1)
#define WDT_STATUS_RST_ENA			(1 << 2)
#define WDT_STATUS_AFTER_RST_ENA	(1 << 3)
#define WDT_STATUS_TIMED_OUT_IRQ	(1 << 4) /* 1st level timeout */
#define WDT_STATUS_TIMED_OUT_RST	(1 << 5) /* 2nd level timeout */

struct attiny_dev {
	struct i2c_client *client;
	struct mutex io_lock;
	int (*read)(struct attiny_dev *attiny, u8 reg, u8 *data);
	int (*write)(struct attiny_dev *attiny, u8 reg, u8 data);
	void (*lock)(struct attiny_dev *attiny);
	void (*unlock)(struct attiny_dev *attiny);
};

#endif
