package device

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/iniwex5/quectel-qmi-go/pkg/qmi"
	"github.com/iniwex5/vohive/internal/backend"
	"github.com/iniwex5/vohive/internal/modem"
	"github.com/iniwex5/vohive/pkg/logger"
)

var (
	ErrWorkerNil                     = errors.New("worker_nil")
	ErrBackendNotAvailable           = errors.New("backend_not_available")
	ErrOperatorSelectionNotSupported = errors.New("operator_selection_not_supported")
	ErrVoWiFiActive                  = errors.New("vowifi_active")
	ErrESIMSwitching                 = errors.New("esim_profile_switching")
)

const operatorScanTimeout = 120 * time.Second
const operatorScanRetryableMessage = "扫描超时或模组忙，请稍后重试"

type OperatorScanStatus string

const (
	OperatorScanStatusRunning  OperatorScanStatus = "running"
	OperatorScanStatusComplete OperatorScanStatus = "complete"
	OperatorScanStatusFailed   OperatorScanStatus = "failed"
)

type OperatorScanResult struct {
	ScanID     string
	Status     OperatorScanStatus
	StartedAt  time.Time
	UpdatedAt  time.Time
	Complete   bool
	Retryable  bool
	Message    string
	Candidates []backend.OperatorCandidate
	Err        string
}

func (w *Worker) ScanOperators(ctx context.Context) ([]backend.OperatorCandidate, error) {
	if w == nil {
		return nil, ErrWorkerNil
	}
	if w.Backend == nil {
		return nil, ErrBackendNotAvailable
	}

	provider, ok := w.Backend.(backend.OperatorSelectionProvider)
	if !ok {
		return nil, ErrOperatorSelectionNotSupported
	}

	candidates, err := provider.ScanOperators(ctx)
	if err != nil {
		atPort := w.ResolvedATPort()
		if atPort != "" {
			if atCandidates, atErr := tryScanOperatorsViaAT(atPort); atErr == nil && len(atCandidates) > 0 {
				logger.Info("provider 搜网失败，已通过 AT 端口降级完成搜网", "device", w.ID, "at_port", atPort, "err", err, "count", len(atCandidates))
				return atCandidates, nil
			} else if atErr != nil {
				logger.Warn("provider 搜网失败且 AT 降级也失败", "device", w.ID, "provider_err", err, "at_err", atErr)
			}
		}
	}
	return candidates, err
}

type incrementalOperatorScanProvider interface {
	IncrementalOperatorScanSnapshot() ([]backend.OperatorCandidate, bool, time.Time, bool)
}

func isRetryableOperatorScanError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return true
	}
	text := strings.ToLower(err.Error())
	if strings.Contains(text, "mbim: visible_providers") &&
		(strings.Contains(text, "status=") || strings.Contains(text, "deadline") || strings.Contains(text, "timeout")) {
		return true
	}
	qe := qmi.GetQMIError(err)
	if qe != nil && qe.Service == qmi.ServiceNAS && qe.MessageID == qmi.NASPerformNetworkScan {
		if qe.ErrorCode == qmi.QMIErrInternal || qe.ErrorCode == 0x0046 || qe.ErrorCode == 0x0019 {
			return true
		}
	}
	return false
}

func (w *Worker) IsOperatorScanActive() bool {
	if w == nil {
		return false
	}
	w.operatorScanMu.Lock()
	defer w.operatorScanMu.Unlock()
	return w.operatorScanActive
}

func (w *Worker) GetOperatorScanSnapshot() OperatorScanResult {
	if w == nil {
		return OperatorScanResult{
			Status:    OperatorScanStatusFailed,
			Retryable: false,
			Message:   ErrWorkerNil.Error(),
			Err:       ErrWorkerNil.Error(),
		}
	}
	w.operatorScanMu.Lock()
	w.expireOperatorScanLocked(time.Now())
	current := w.operatorScanCurrent
	w.operatorScanMu.Unlock()
	w.mergeIncrementalOperatorScan(&current)
	return current
}

func (w *Worker) StartOrGetOperatorScan(ctx context.Context) OperatorScanResult {
	if w == nil {
		return OperatorScanResult{
			Status:    OperatorScanStatusFailed,
			Retryable: false,
			Message:   ErrWorkerNil.Error(),
			Err:       ErrWorkerNil.Error(),
		}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	now := time.Now()
	w.operatorScanMu.Lock()
	if w.expireOperatorScanLocked(now) {
		current := w.operatorScanCurrent
		w.operatorScanMu.Unlock()
		w.mergeIncrementalOperatorScan(&current)
		return current
	}
	if w.operatorScanActive {
		current := w.operatorScanCurrent
		w.operatorScanMu.Unlock()
		w.mergeIncrementalOperatorScan(&current)
		return current
	}
	scanCtx, cancel := context.WithTimeout(context.Background(), operatorScanTimeout)
	current := OperatorScanResult{
		ScanID:    fmt.Sprintf("%s-%d", w.ID, now.UnixNano()),
		Status:    OperatorScanStatusRunning,
		StartedAt: now,
		UpdatedAt: now,
		Message:   "扫描进行中",
	}
	w.operatorScanCurrent = current
	w.operatorScanCancel = cancel
	w.operatorScanActive = true
	w.operatorScanMu.Unlock()

	go w.runOperatorScan(scanCtx, cancel, current.ScanID)
	return current
}

func (w *Worker) runOperatorScan(ctx context.Context, cancel context.CancelFunc, scanID string) {
	defer cancel()
	candidates, err := w.ScanOperators(ctx)
	result := OperatorScanResult{}
	w.operatorScanMu.Lock()
	if w.operatorScanCurrent.ScanID != scanID || w.operatorScanCurrent.Status != OperatorScanStatusRunning {
		w.operatorScanMu.Unlock()
		return
	}
	result = w.operatorScanCurrent
	if err != nil {
		result.Status = OperatorScanStatusFailed
		result.UpdatedAt = time.Now()
		result.Err = err.Error()
		if isRetryableOperatorScanError(err) {
			result.Retryable = true
			qe := qmi.GetQMIError(err)
			if qe != nil && qe.ErrorCode == 0x0046 {
				result.Message = "模组当前正在进行后台搜网或注册，射频正忙，请稍后重试"
			} else {
				result.Message = operatorScanRetryableMessage
			}
		} else {
			result.Message = err.Error()
		}
	} else {
		result.Status = OperatorScanStatusComplete
		result.UpdatedAt = time.Now()
		result.Complete = true
		result.Message = "扫描完成"
		result.Candidates = candidates
	}
	w.operatorScanCurrent = result
	w.operatorScanCancel = nil
	w.operatorScanActive = false
	w.operatorScanMu.Unlock()
}

func (w *Worker) expireOperatorScanLocked(now time.Time) bool {
	if !w.operatorScanActive || w.operatorScanCurrent.Status != OperatorScanStatusRunning {
		return false
	}
	if w.operatorScanCurrent.StartedAt.IsZero() || now.Sub(w.operatorScanCurrent.StartedAt) < operatorScanTimeout {
		return false
	}
	if w.operatorScanCancel != nil {
		w.operatorScanCancel()
	}
	result := w.operatorScanCurrent
	result.Status = OperatorScanStatusFailed
	result.UpdatedAt = now
	result.Retryable = true
	result.Message = operatorScanRetryableMessage
	result.Err = context.DeadlineExceeded.Error()
	w.operatorScanCurrent = result
	w.operatorScanCancel = nil
	w.operatorScanActive = false
	return true
}

func (w *Worker) mergeIncrementalOperatorScan(result *OperatorScanResult) {
	if w == nil || result == nil || w.Backend == nil {
		return
	}
	provider, ok := w.Backend.(incrementalOperatorScanProvider)
	if !ok {
		return
	}
	candidates, complete, ts, ok := provider.IncrementalOperatorScanSnapshot()
	if !ok || ts.Before(result.StartedAt) {
		return
	}
	result.Candidates = candidates
	result.Complete = complete
	result.UpdatedAt = ts
}

func (w *Worker) GetOperatorSelection(ctx context.Context) (backend.OperatorSelection, error) {
	if w == nil {
		return backend.OperatorSelection{}, ErrWorkerNil
	}
	if w.Backend == nil {
		return backend.OperatorSelection{}, ErrBackendNotAvailable
	}

	if w.Config.OperatorSelectionMode == string(backend.OperatorSelectionManual) && w.Config.OperatorSelectionPLMN != "" {
		if sel, err := backend.NormalizeManualOperatorSelection(
			w.Config.OperatorSelectionPLMN,
			backend.OperatorAccessTechnology(w.Config.OperatorSelectionRAT),
			nil,
		); err == nil {
			return sel, nil
		}
	}

	provider, ok := w.Backend.(backend.OperatorSelectionProvider)
	if !ok {
		return backend.OperatorSelection{}, ErrOperatorSelectionNotSupported
	}

	return provider.GetOperatorSelection(ctx)
}

func (w *Worker) SetOperatorSelection(ctx context.Context, req backend.SetOperatorSelectionRequest) (backend.OperatorSelection, error) {
	if w == nil {
		return backend.OperatorSelection{}, ErrWorkerNil
	}
	if w.Backend == nil {
		return backend.OperatorSelection{}, ErrBackendNotAvailable
	}

	if w.Pool != nil {
		if w.Pool.IsVoWiFiActive(w.ID) {
			return backend.OperatorSelection{}, ErrVoWiFiActive
		}
		if w.Pool.IsESIMSwitching(w.ID) {
			return backend.OperatorSelection{}, ErrESIMSwitching
		}
	}

	provider, ok := w.Backend.(backend.OperatorSelectionProvider)
	if !ok {
		return backend.OperatorSelection{}, ErrOperatorSelectionNotSupported
	}

	res, err := provider.SetOperatorSelection(ctx, req)
	if err != nil {
		atPort := w.ResolvedATPort()
		if atPort != "" {
			selReq := backend.OperatorSelection{
				Mode: req.Mode,
				PLMN: req.PLMN,
				RAT:  req.RAT,
			}
			if req.Mode == backend.OperatorSelectionManual && req.PLMN != "" {
				if norm, nerr := backend.NormalizePLMNSelection(req.PLMN); nerr == nil {
					selReq.MCC = norm.MCC
					selReq.MNC = norm.MNC
					selReq.MNCLength = norm.MNCLength
					selReq.IncludesPCSDigit = norm.IncludesPCSDigit
				}
			}
			if atErr := tryManualRegistrationViaAT(atPort, selReq); atErr == nil {
				logger.Info("provider 设置选网失败，已通过 AT 端口降级执行", "device", w.ID, "at_port", atPort, "err", err)
				res = selReq
				err = nil
			} else {
				logger.Warn("provider 设置选网失败且 AT 降级也失败", "device", w.ID, "provider_err", err, "at_err", atErr)
			}
		}
	}
	if err != nil {
		return backend.OperatorSelection{}, err
	}

	// Update worker memory config
	w.Config.OperatorSelectionMode = string(req.Mode)
	w.Config.OperatorSelectionPLMN = req.PLMN
	if req.Mode == backend.OperatorSelectionManual && req.PLMN != "" {
		if norm, nerr := backend.NormalizePLMNSelection(req.PLMN); nerr == nil {
			w.Config.OperatorSelectionPLMN = norm.PLMN
		}
	}
	w.Config.OperatorSelectionRAT = string(req.RAT)

	w.RefreshRuntime(ctx, "operator_selection_change")

	if w.Config.NetworkEnabled {
		switch w.Config.DeviceBackend {
		case backend.BackendQMI:
			w.StartQMIRegistrationReconcile(ctx, "operator_selection_change")
		case backend.BackendMBIM:
			w.StartMBIMRegistrationReconcile(ctx, "operator_selection_change")
		}
	}

	return res, nil
}

func tryScanOperatorsViaAT(atPort string) ([]backend.OperatorCandidate, error) {
	atPort = strings.TrimSpace(atPort)
	if atPort == "" {
		return nil, fmt.Errorf("empty at port")
	}
	session, err := modem.NewSerialAT(atPort, 115200, 8, 1, "N")
	if err != nil {
		return nil, fmt.Errorf("open at port %s failed: %w", atPort, err)
	}
	defer session.Close()

	resp, err := session.Execute("AT+COPS=?", 90*time.Second)
	if err != nil {
		return nil, fmt.Errorf("execute AT+COPS=? failed: %w", err)
	}

	entries := modem.ParseCOPSScan(resp)
	var candidates []backend.OperatorCandidate
	for _, entry := range entries {
		var status string
		switch entry.Status {
		case 1:
			status = "available"
		case 2:
			status = "current"
		case 3:
			status = "forbidden"
		default:
			status = "unknown"
		}

		rat := backend.AtActToRAT(entry.Act)
		var rats []backend.OperatorAccessTechnology
		if rat != backend.OperatorRATUnknown {
			rats = []backend.OperatorAccessTechnology{rat}
		}

		candidate := backend.OperatorCandidate{
			PLMN:         entry.PLMN,
			OperatorName: entry.LongName,
			ShortName:    entry.ShortName,
			Status:       status,
			RATs:         rats,
		}

		if normalized, err := backend.NormalizePLMNSelection(entry.PLMN); err == nil {
			candidate.MCC = normalized.MCC
			candidate.MNC = normalized.MNC
			candidate.MNCLength = normalized.MNCLength
			candidate.IncludesPCSDigit = normalized.IncludesPCSDigit
		}

		candidates = append(candidates, candidate)
	}
	return candidates, nil
}
