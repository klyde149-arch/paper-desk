# lib_rf_riskdto.ps1 - перевод полей риск-политики из состояния движка в DTO отчётных поверхностей.
# ТОЛЬКО переименование: ни одного расчёта. Считает всё движок (risk_view карточки и st.risk_budget),
# поверхности показывают готовые числа - до 2026-09 дашборд, снапшот и ассистент считали проценты
# каждый по-своему и давали на одну позицию три разных ответа (см. BACKLOG №24).
# Дот-сорсится отчётными скриптами (bake_rf_candles.ps1, build_vizdata.ps1), но НЕ движком:
# движок не должен зависеть от формата отчётности.

# risk_view карточки -> DTO позиции. $null (режим off или карточка до политики) остаётся $null:
# поверхность обязана рисовать прочерк, а не ноль.
function ConvertTo-RfRiskViewDto($V) {
  if ($null -eq $V) { return $null }
  return [ordered]@{
    policyId = [string]$V.policy_id; mode = [string]$V.mode
    stopPx = $V.stop_px; stopDistPct = $V.stop_dist_pct
    riskRub = $V.risk_rub; riskPctAccount = $V.risk_pct_account
    feesEstimated = [bool]$V.fees_estimated; protection = [string]$V.protection
    entryPxStatus = [string]$V.entry_px_status; budgetLeftRub = $V.budget_left_rub
  }
}
# st.risk_budget -> DTO сводки. Массивы причин отдаём всегда массивами: фронт их перебирает.
function ConvertTo-RfRiskBudgetDto($B) {
  if ($null -eq $B) { return $null }
  $byAsset = [ordered]@{}
  if ($null -ne $B.by_asset) {
    foreach ($pr in @($B.by_asset.PSObject.Properties)) { $byAsset[$pr.Name] = $pr.Value }
  }
  return [ordered]@{
    mode = [string]$B.mode; policyId = [string]$B.policy_id; updatedMs = $B.updated_ms
    capitalRub = $B.capital_rub; capitalOk = [bool]$B.capital_ok; capitalReason = [string]$B.capital_reason
    totalUsedRub = $B.total_used_rub; totalCapRub = $B.total_cap_rub
    fxLongRub = $B.fx_long_rub; fxShortRub = $B.fx_short_rub; fxCapRub = $B.fx_cap_rub
    byAsset = $byAsset
    dayOk = [bool]$B.day_ok; dayPnlRub = $B.day_pnl_rub; dayLimitRub = $B.day_limit_rub
    dayReason = [string]$B.day_reason
    unknown = @($B.unknown | Where-Object { $null -ne $_ })
    reasons = @($B.reasons | Where-Object { $null -ne $_ })
  }
}
