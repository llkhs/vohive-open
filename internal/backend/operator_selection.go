package backend

import (
	"context"
	"fmt"
	"strconv"
)

type OperatorSelectionMode string

const (
	OperatorSelectionAutomatic OperatorSelectionMode = "automatic"
	OperatorSelectionManual    OperatorSelectionMode = "manual"
)

type OperatorAccessTechnology string

const (
	OperatorRATUnknown OperatorAccessTechnology = ""
	OperatorRATGSM     OperatorAccessTechnology = "gsm"
	OperatorRATWCDMA   OperatorAccessTechnology = "wcdma"
	OperatorRATLTE     OperatorAccessTechnology = "lte"
	OperatorRATNR5G    OperatorAccessTechnology = "nr5g"
)

type OperatorSelection struct {
	Mode             OperatorSelectionMode    `json:"mode"`
	PLMN             string                   `json:"plmn,omitempty"`
	MCC              string                   `json:"mcc,omitempty"`
	MNC              string                   `json:"mnc,omitempty"`
	MNCLength        int                      `json:"mnc_length,omitempty"`
	IncludesPCSDigit bool                     `json:"includes_pcs_digit,omitempty"`
	RAT              OperatorAccessTechnology `json:"rat,omitempty"`
	OperatorName     string                   `json:"operator_name,omitempty"`
}

type OperatorCandidate struct {
	PLMN             string                     `json:"plmn"`
	MCC              string                     `json:"mcc"`
	MNC              string                     `json:"mnc"`
	MNCLength        int                        `json:"mnc_length"`
	IncludesPCSDigit bool                       `json:"includes_pcs_digit"`
	OperatorName     string                     `json:"operator_name"`
	ShortName        string                     `json:"short_name,omitempty"`
	Status           string                     `json:"status"`
	RATs             []OperatorAccessTechnology `json:"rats,omitempty"`
}

type SetOperatorSelectionRequest struct {
	Mode             OperatorSelectionMode    `json:"mode"`
	PLMN             string                   `json:"plmn,omitempty"`
	MCC              string                   `json:"mcc,omitempty"`
	MNC              string                   `json:"mnc,omitempty"`
	MNCLength        int                      `json:"mnc_length,omitempty"`
	IncludesPCSDigit *bool                    `json:"includes_pcs_digit,omitempty"`
	RAT              OperatorAccessTechnology `json:"rat,omitempty"`
}

type OperatorSelectionProvider interface {
	ScanOperators(ctx context.Context) ([]OperatorCandidate, error)
	GetOperatorSelection(ctx context.Context) (OperatorSelection, error)
	SetOperatorSelection(ctx context.Context, req SetOperatorSelectionRequest) (OperatorSelection, error)
}

func NormalizePLMNSelection(plmn string) (OperatorSelection, error) {
	if len(plmn) != 5 && len(plmn) != 6 {
		return OperatorSelection{}, fmt.Errorf("invalid plmn length: %d", len(plmn))
	}
	for _, c := range plmn {
		if c < '0' || c > '9' {
			return OperatorSelection{}, fmt.Errorf("invalid character in plmn: %c", c)
		}
	}

	mcc := plmn[:3]
	mnc := plmn[3:]

	// 兼容处理中国大陆 (MCC 460) 被误格式化为 3 位 MNC 的 6 位 PLMN（例如 460001 -> 46001, 460011 -> 46011, 460000 -> 46000）
	// 中国大陆所有运营商 MNC 均为 2 位数
	if mcc == "460" && len(plmn) == 6 && mnc[0] == '0' {
		mnc = mnc[1:]
		plmn = mcc + mnc
	}

	mncLength := len(mnc)
	pcs := mncLength == 3

	return OperatorSelection{
		PLMN:             plmn,
		MCC:              mcc,
		MNC:              mnc,
		MNCLength:        mncLength,
		IncludesPCSDigit: pcs,
	}, nil
}

func NormalizeManualOperatorSelection(plmn string, rat OperatorAccessTechnology, includesPCS *bool) (OperatorSelection, error) {
	sel, err := NormalizePLMNSelection(plmn)
	if err != nil {
		return OperatorSelection{}, err
	}
	sel.Mode = OperatorSelectionManual
	sel.RAT = rat
	if includesPCS != nil {
		sel.IncludesPCSDigit = *includesPCS
	}
	return sel, nil
}

func NormalizeSetOperatorSelectionRequest(req SetOperatorSelectionRequest) (OperatorSelection, error) {
	if err := ValidateSetOperatorSelectionRequest(req); err != nil {
		return OperatorSelection{}, err
	}
	if req.Mode == OperatorSelectionAutomatic {
		return OperatorSelection{Mode: OperatorSelectionAutomatic}, nil
	}
	return NormalizeManualOperatorSelection(req.PLMN, req.RAT, req.IncludesPCSDigit)
}

func BuildManualNASRegisterRequest(sel OperatorSelection) (NASRegisterRequest, error) {
	if sel.Mode != OperatorSelectionManual {
		return NASRegisterRequest{}, fmt.Errorf("manual operator selection required")
	}
	mcc, err := strconv.ParseUint(sel.MCC, 10, 16)
	if err != nil {
		return NASRegisterRequest{}, err
	}
	mnc, err := strconv.ParseUint(sel.MNC, 10, 16)
	if err != nil {
		return NASRegisterRequest{}, err
	}

	return NASRegisterRequest{
		Mode:             "manual",
		MCC:              uint16(mcc),
		MNC:              uint16(mnc),
		IncludesPCSDigit: sel.IncludesPCSDigit,
		RadioAccessTech:  OperatorRATToNASRadioAccessTech(sel.RAT),
	}, nil
}

func OperatorRATToNASRadioAccessTech(rat OperatorAccessTechnology) uint8 {
	switch rat {
	case OperatorRATGSM:
		return 0x04
	case OperatorRATWCDMA:
		return 0x05
	case OperatorRATLTE:
		return 0x08
	case OperatorRATNR5G:
		return 0x0C
	default:
		return 0x00
	}
}

func ValidateSetOperatorSelectionRequest(req SetOperatorSelectionRequest) error {
	switch req.Mode {
	case OperatorSelectionAutomatic:
		return nil
	case OperatorSelectionManual:
		if req.PLMN == "" {
			return fmt.Errorf("plmn is required for manual mode")
		}
		_, err := NormalizePLMNSelection(req.PLMN)
		return err
	default:
		return fmt.Errorf("invalid mode: %s", req.Mode)
	}
}
