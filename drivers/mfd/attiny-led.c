// SPDX-License-Identifier: GPL-2.0
/*
 * LED driver for the ATtiny system management MCU on the Avnet SmartEdge
 * IIoT Gateway.
 *
 * Exposes two colour LEDs ("red" and "green") plus two raw register
 * passthrough LEDs ("smartedge_led" -> I2C_LED_STATE and
 * "smartedge_led_duty" -> I2C_LED_DUTY) which are kept for compatibility
 * with the user space shipped on the original firmware.
 */

#include <linux/leds.h>
#include <linux/module.h>
#include <linux/platform_device.h>

#include "attiny.h"

enum attiny_led_mode {
	ATTINY_LED_COLOUR,	/* one of the two front panel LEDs */
	ATTINY_LED_STATE,	/* raw write to I2C_LED_STATE */
	ATTINY_LED_DUTY,	/* raw write to I2C_LED_DUTY */
};

struct attiny_led {
	struct led_classdev cdev;
	struct attiny_dev *attiny;
	enum attiny_led_mode mode;
	u8 mask;		/* colour bit in I2C_LED_STATE */
};

#define ATTINY_LED_BLINK	0x40	/* I2C_LED_STATE bit 6 */
#define ATTINY_LED_RATE_MASK	0x07	/* I2C_LED_STATE bits [2:0] */
#define ATTINY_LED_SOLID	0x07	/* rate '111' = on */

static struct attiny_led *to_attiny_led(struct led_classdev *cdev)
{
	return container_of(cdev, struct attiny_led, cdev);
}

static int attiny_led_set(struct led_classdev *cdev, enum led_brightness value)
{
	struct attiny_led *led = to_attiny_led(cdev);
	struct attiny_dev *attiny = led->attiny;
	u8 state = 0;

	attiny->lock(attiny);

	switch (led->mode) {
	case ATTINY_LED_STATE:
		attiny->write(attiny, I2C_LED_STATE, (u8)value);
		break;
	case ATTINY_LED_DUTY:
		attiny->write(attiny, I2C_LED_DUTY, (u8)value);
		break;
	case ATTINY_LED_COLOUR:
		attiny->read(attiny, I2C_LED_STATE, &state);
		if (value) {
			state |= led->mask;
			state |= ATTINY_LED_SOLID;
			state &= ~ATTINY_LED_BLINK;
			attiny->write(attiny, I2C_LED_DUTY, 0x7f);
		} else {
			state &= ~led->mask;
			state &= ~(ATTINY_LED_RATE_MASK | ATTINY_LED_BLINK);
			attiny->write(attiny, I2C_LED_DUTY, 0);
		}
		attiny->write(attiny, I2C_LED_STATE, state);
		break;
	}

	attiny->unlock(attiny);

	return 0;
}

static int attiny_led_blink_set(struct led_classdev *cdev,
				unsigned long *delay_on, unsigned long *delay_off)
{
	struct attiny_led *led = to_attiny_led(cdev);
	struct attiny_dev *attiny = led->attiny;
	unsigned long period;
	u8 state, rate, duty;

	/* Only the colour LEDs support hardware accelerated blinking. */
	if (led->mode != ATTINY_LED_COLOUR)
		return -EINVAL;

	if (!*delay_on && !*delay_off)
		*delay_on = *delay_off = 500;

	/* Keep the arithmetic below well inside 32 bits. */
	if (*delay_on > 30000)
		*delay_on = 30000;
	if (*delay_off > 30000)
		*delay_off = 30000;

	period = *delay_on + *delay_off;

	/* Available rates: 1 slow (1Hz), 2 medium (2Hz), 3 fast (4Hz), 4 v.fast */
	if (period >= 1000)
		rate = 1;
	else if (period >= 500)
		rate = 2;
	else if (period >= 250)
		rate = 3;
	else
		rate = 4;

	duty = (u8)(*delay_on * 0xff / period);
	if (!duty)
		duty = 1;

	attiny->lock(attiny);
	attiny->read(attiny, I2C_LED_STATE, &state);
	state &= ~ATTINY_LED_RATE_MASK;
	state |= rate;
	state |= ATTINY_LED_BLINK;
	state |= led->mask;
	attiny->write(attiny, I2C_LED_STATE, state);
	attiny->write(attiny, I2C_LED_DUTY, duty);
	attiny->unlock(attiny);

	return 0;
}

static int attiny_led_probe(struct platform_device *pdev)
{
	struct attiny_dev *attiny = dev_get_drvdata(pdev->dev.parent);
	struct attiny_led *leds;
	u8 i;
	int ret;

	leds = devm_kzalloc(&pdev->dev, sizeof(*leds) * 4, GFP_KERNEL);
	if (!leds)
		return -ENOMEM;

	leds[0].attiny = attiny;
	leds[0].mode = ATTINY_LED_COLOUR;
	leds[0].mask = 0x20;		/* red */
	leds[0].cdev.name = "red";
	leds[0].cdev.color = LED_COLOR_ID_RED;
	leds[0].cdev.max_brightness = LED_FULL;

	leds[1].attiny = attiny;
	leds[1].mode = ATTINY_LED_COLOUR;
	leds[1].mask = 0x10;		/* green */
	leds[1].cdev.name = "green";
	leds[1].cdev.color = LED_COLOR_ID_GREEN;
	leds[1].cdev.max_brightness = LED_FULL;

	leds[2].attiny = attiny;
	leds[2].mode = ATTINY_LED_STATE;
	leds[2].cdev.name = "smartedge_led";
	leds[2].cdev.max_brightness = 0xff;

	leds[3].attiny = attiny;
	leds[3].mode = ATTINY_LED_DUTY;
	leds[3].cdev.name = "smartedge_led_duty";
	leds[3].cdev.max_brightness = 0xff;

	for (i = 0; i < 4; i++) {
		leds[i].cdev.brightness_set_blocking = attiny_led_set;
		leds[i].cdev.blink_set = attiny_led_blink_set;

		ret = devm_led_classdev_register(&pdev->dev, &leds[i].cdev);
		if (ret)
			return ret;
	}

	attiny->lock(attiny);
	attiny->write(attiny, I2C_LED_DUTY, 0x7f);
	attiny->read(attiny, I2C_FW_REV, &i);
	dev_info(&pdev->dev, "ATtiny MCU firmware revision %u\n", i);
	attiny->read(attiny, I2C_HW_REV, &i);
	dev_info(&pdev->dev, "ATtiny MCU hardware revision %u\n", i);
	attiny->unlock(attiny);

	return 0;
}

static struct platform_driver attiny_led_driver = {
	.driver = {
		.name = "attiny-led",
	},
	.probe = attiny_led_probe,
};

module_platform_driver(attiny_led_driver);

MODULE_AUTHOR("Dale P. Smith <dales@avid-tech.com>");
MODULE_DESCRIPTION("ATtiny LED driver");
MODULE_LICENSE("GPL");
