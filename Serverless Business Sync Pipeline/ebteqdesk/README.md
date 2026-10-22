# Ebteqdesk 侧改动 / Ebteqdesk-side changes

> 这个文件夹**只有文档**。v3 的 Laravel trigger API 源码（controller、routes、`BusinessSyncTriggerApiTest`）不在这个仓库里，
> 所以这里只说明 v4 需要在 **Ebteqdesk repo** 里做的改动，改动要在 Ebteqdesk repo 里完成并跑 test。
> Sync logic（`SyncBusinessContacts`、`BusinessSynchronizer`、`BusinessRecordDiff`、`DuplicateDetector`、`BusinessSyncJournal`）**不改**。

## API contract（不变）

| Method | Path | Headers | Response |
|---|---|---|---|
| `POST` | `/api/integrations/business-sync/{salonv3\|warni}` | `Authorization: Bearer <BUSINESS_SYNC_TRIGGER_TOKEN>`、`X-Trigger-Id: [A-Za-z0-9:._-]{1,100}` | `202` 新 run；`200` 已在跑的 run |
| `GET` | `/api/integrations/business-sync/runs/{id}` | `Authorization: Bearer …` | `status`（`queued\|running\|succeeded\|failed`）、`exit_code`、`error`、`accepted_at`、`started_at`、`finished_at`、`output`（跑完才有） |

## 需要的改动：`BusinessSyncTriggerController::store`

**现在（v3）：** 只有**同一个** `X-Trigger-Id` 的 active run 会被回传 `200`，不同 trigger id 会开第二个 sweep。
**改成（v4）：** 这个 portal **任何** active、未 stale 的 run 都回传 `200`，不管 `X-Trigger-Id` 是什么。
新 run 仍然存 caller 的 `trigger_id`。

为什么：sync 改成每小时跑。重试（~15 分钟后）和下一个整点、或手动触发，都可能碰上还在跑的 sweep；同一个 brand 同时只能有一个 sweep。

示意（按实际的 model / 字段名调整）：

```php
public function store(Request $request, string $portal)
{
    $triggerId = $this->validatedTriggerId($request);   // 现有的 X-Trigger-Id 验证

    return DB::transaction(function () use ($portal, $triggerId) {
        $active = BusinessSyncRemoteRun::query()
            ->where('portal', $portal)
            ->whereIn('status', ['queued', 'running'])
            ->lockForUpdate()
            ->latest('accepted_at')
            ->first();

        if ($active && ! $active->isStale()) {
            return BusinessSyncRemoteRunResource::make($active)->response()->setStatusCode(200);  // 不看 trigger_id
        }

        if ($active) {
            $active->markAbandoned();   // stale：沿用现有的 abandon 逻辑
        }

        $run = BusinessSyncRemoteRun::create([
            'portal'     => $portal,
            'trigger_id' => $triggerId,  // 继续存 caller 的 trigger id
            'status'     => 'queued',
            'accepted_at'=> now(),
        ]);

        RunRemoteBusinessSync::dispatchAfterResponse($run);   // 现有写法不变

        return BusinessSyncRemoteRunResource::make($run)->response()->setStatusCode(202);
    });
}
```

## Feature tests（加进 `tests/Feature/Api/BusinessSyncTriggerApiTest.php`）

1. **an active run from another trigger is returned instead of starting a second sweep**：先建一个 `running`、未 stale、`trigger_id = manual-1` 的 run；用 `X-Trigger-Id: sched-2026-09-28T01:00:00Z` POST → `200`、回传同一个 id、`business_sync_remote_runs` 仍然只有 1 笔、没有 dispatch job。
2. **a stale active run from another trigger is abandoned and a new sweep starts**：先建一个超过 stale 门槛的 `running` run（`trigger_id = manual-1`）；用另一个 trigger id POST → `202`、旧 run 变成 abandoned/failed、新 run 的 `trigger_id` 是 caller 的。
3. 原有的"same trigger id returns the active run"继续通过。

跑：`php artisan test tests/Feature/Api/BusinessSyncTriggerApiTest.php`

## 注意：sweep 现在在上班时间跑

sweep 现在是 **Mon–Fri 09:00–17:30 每小时**，也就是 agent 正在用 Ebteqdesk 的时候。sweep 在 HTTP response 之后跑（`dispatchAfterResponse`，`QUEUE_DRIVER=sync`），会占用一个 web worker。

- 第一周之后，到 **Settings → Business Sync** 看每次 run 的 `durationMs`。
- 如果 sweep 超过 **约 60 秒**，或 agent 反映变慢，下一步是加 queue worker：把 `RunRemoteBusinessSync` 改成 `ShouldQueue`，
  由 Laravel Cloud 的 queue worker 跑。**这一步现在只记录、不实作。**
- Laravel 自带的 Business Sync schedule switch **两个 brand 都保持 OFF**，AWS 是唯一的 scheduler。
