/*
 * SPDX-FileCopyrightText: 2024-2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdlib.h>
#include <stdbool.h>
#include <inttypes.h>
#include "sdkconfig.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_at.h"
#include "esp_at_check_config.h"

static const char *TAG = "at-mem";

#define AT_MEM_MONITOR_ARRAY_SIZE_OFFSET    4

static bool at_mem_check_internal(const char *tag, int value, bool verbose)
{
    bool healthy = true;
    const char *site = (tag != NULL) ? tag : "?";
    UBaseType_t array_size = uxTaskGetNumberOfTasks() + AT_MEM_MONITOR_ARRAY_SIZE_OFFSET;
    TaskStatus_t *task_array = (TaskStatus_t *)malloc(array_size * sizeof(TaskStatus_t));
    if (task_array == NULL) {
        ESP_AT_LOGE(TAG, "malloc failed @ %s:%d", site, value);
        return false;
    }

    UBaseType_t task_count = uxTaskGetSystemState(task_array, array_size, NULL);
    if (task_count == 0) {
        ESP_AT_LOGE(TAG, "uxTaskGetSystemState failed @ %s:%d", site, value);
        free(task_array);
        return false;
    }

    if (verbose) {
        ESP_AT_LOGI(TAG, "---- task stack high watermark (remaining free bytes) @ %s:%d ----", site, value);
    }
    for (UBaseType_t i = 0; i < task_count; i++) {
        uint32_t watermark_bytes = (uint32_t)task_array[i].usStackHighWaterMark * sizeof(StackType_t);
        if (watermark_bytes < (uint32_t)CONFIG_AT_MEM_MONITOR_STACK_RISK_BYTES) {
            healthy = false;
            ESP_AT_LOGE(TAG, "stack overflow risk! task:%s prio:%u remaining:%" PRIu32 " bytes @ %s:%d",
                        task_array[i].pcTaskName,
                        (unsigned)task_array[i].uxCurrentPriority,
                        watermark_bytes,
                        site, value);
        } else if (verbose) {
            ESP_AT_LOGI(TAG, "task:%-16s prio:%u remaining:%" PRIu32 " bytes",
                        task_array[i].pcTaskName,
                        (unsigned)task_array[i].uxCurrentPriority,
                        watermark_bytes);
        }
    }
    free(task_array);

    /* Without IDF heap poisoning this mainly validates heap metadata. */
    if (!heap_caps_check_integrity_all(verbose)) {
        healthy = false;
        ESP_AT_LOGE(TAG, "heap corruption detected @ %s:%d", site, value);
    } else if (verbose) {
        ESP_AT_LOGI(TAG, "heap integrity check: OK @ %s:%d", site, value);
    }

    return healthy;
}

bool esp_at_mem_check(const char *tag, int value)
{
    return at_mem_check_internal(tag, value, true);
}

static void at_mem_monitor_task(void *params)
{
    (void)params;
    ESP_AT_LOGI(TAG, "mem-monitor task started, interval=%d ms", CONFIG_AT_MEM_MONITOR_INTV_MS);
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(CONFIG_AT_MEM_MONITOR_INTV_MS));
        /* Quiet path: only log stack risk / heap corruption. */
        at_mem_check_internal("periodic", 0, false);
    }
}

static uint8_t at_exe_cmd_sysmemchk(uint8_t *cmd_name)
{
    (void)cmd_name;
    if (!esp_at_mem_check("+SYSMEMCHK", 0)) {
        return ESP_AT_RESULT_CODE_ERROR;
    }
    return ESP_AT_RESULT_CODE_OK;
}

static const esp_at_cmd_t s_at_mem_monitor_cmd[] = {
    {"+SYSMEMCHK", NULL, NULL, NULL, at_exe_cmd_sysmemchk},
};

bool esp_at_mem_monitor_cmd_register(void)
{
    // periodic stack watermark + heap integrity check
    if (xTaskCreate(at_mem_monitor_task, "mem-monitor", 3072, NULL, 1, NULL) != pdPASS) {
        ESP_AT_LOGE(TAG, "failed to create mem-monitor task");
        return false;
    }

    if (!esp_at_custom_cmd_array_register(s_at_mem_monitor_cmd, sizeof(s_at_mem_monitor_cmd) / sizeof(s_at_mem_monitor_cmd[0]))) {
        return false;
    }
    return true;
}

ESP_AT_CMD_SET_FIRST_INIT_FN(esp_at_mem_monitor_cmd_register, 27);
