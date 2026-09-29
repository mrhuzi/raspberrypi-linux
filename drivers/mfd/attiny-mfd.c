// SPDX-License-Identifier: GPL-2.0
/*
 * MFD core driver for the ATtiny system management MCU on the Avnet
 * SmartEdge IIoT Gateway.
 *
 * The MCU stretches the I2C clock, so single byte transfers are retried a
 * few times before giving up.
 */

#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/mfd/core.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>

#include "attiny.h"

/* Workaround I2C clock stretching by retrying failed transfers */
#define ATTINY_IO_RETRIES	5

static const struct mfd_cell attiny_devs[] = {
	{ .name = "attiny-wdt", },
	{ .name = "attiny-led", },
	{ .name = "attiny-btn", },
};

static void attiny_lock(struct attiny_dev *attiny)
{
	mutex_lock(&attiny->io_lock);
}

static void attiny_unlock(struct attiny_dev *attiny)
{
	mutex_unlock(&attiny->io_lock);
}

static int attiny_read(struct attiny_dev *attiny, u8 reg, u8 *data)
{
	struct device *dev = &attiny->client->dev;
	unsigned int retries = 0;
	int ret;

	do {
		ret = i2c_smbus_read_byte_data(attiny->client, reg);
		if (ret >= 0)
			break;
	} while (++retries <= ATTINY_IO_RETRIES);

	if (ret < 0) {
		dev_err(dev, "read of reg 0x%02x failed after %u retries: %pe\n",
			reg, retries, ERR_PTR(ret));
		return ret;
	}

	*data = (u8)ret;
	return 0;
}

static int attiny_write(struct attiny_dev *attiny, u8 reg, u8 data)
{
	struct device *dev = &attiny->client->dev;
	unsigned int retries = 0;
	int ret;

	do {
		ret = i2c_smbus_write_byte_data(attiny->client, reg, data);
		if (ret >= 0)
			break;
	} while (++retries <= ATTINY_IO_RETRIES);

	if (ret < 0)
		dev_err(dev, "write of reg 0x%02x failed after %u retries: %pe\n",
			reg, retries, ERR_PTR(ret));

	return ret;
}

static int attiny_i2c_probe(struct i2c_client *client)
{
	struct attiny_dev *attiny;
	u8 fw_rev = 0, hw_rev = 0;
	int ret;

	attiny = devm_kzalloc(&client->dev, sizeof(*attiny), GFP_KERNEL);
	if (!attiny)
		return -ENOMEM;

	mutex_init(&attiny->io_lock);
	attiny->client = client;
	attiny->read = attiny_read;
	attiny->write = attiny_write;
	attiny->lock = attiny_lock;
	attiny->unlock = attiny_unlock;

	i2c_set_clientdata(client, attiny);

	attiny->lock(attiny);
	attiny->read(attiny, I2C_FW_REV, &fw_rev);
	attiny->read(attiny, I2C_HW_REV, &hw_rev);
	attiny->unlock(attiny);

	dev_info(&client->dev, "ATtiny system MCU at 0x%02x (fw rev %u, hw rev %u)\n",
		 client->addr, fw_rev, hw_rev);

	ret = devm_mfd_add_devices(&client->dev, PLATFORM_DEVID_AUTO,
				   attiny_devs, ARRAY_SIZE(attiny_devs),
				   NULL, 0, NULL);
	if (ret)
		dev_err(&client->dev, "failed to add MFD cells: %pe\n", ERR_PTR(ret));

	return ret;
}

static const struct i2c_device_id attiny_i2c_id[] = {
	{ "attiny" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, attiny_i2c_id);

static const struct of_device_id attiny_of_ids[] = {
	{ .compatible = "avid,attiny" },
	{ }
};
MODULE_DEVICE_TABLE(of, attiny_of_ids);

static struct i2c_driver attiny_i2c_driver = {
	.probe = attiny_i2c_probe,
	.id_table = attiny_i2c_id,
	.driver = {
		.name = "attiny",
		.of_match_table = attiny_of_ids,
	},
};
module_i2c_driver(attiny_i2c_driver);

MODULE_DESCRIPTION("Avnet SmartEdge IIoT Gateway ATtiny multi-function driver");
MODULE_LICENSE("GPL");
