package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/iniwex5/quectel-qmi-go/pkg/qmi"
)

func main() {
	devicePath := "/dev/wwan0qmi0"
	client, err := qmi.NewClientWithOptions(context.Background(), devicePath, qmi.ClientOptions{})
	if err != nil {
		log.Fatalf("Failed to create QMI client: %v", err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	nas, err := qmi.NewNASService(client)
	if err != nil {
		log.Fatalf("Failed to create NAS service: %v", err)
	}
	defer nas.Close()

	cur, err := nas.GetSystemSelectionPreference(ctx)
	if err != nil {
		log.Printf("GetSystemSelectionPreference err: %v", err)
	} else {
		fmt.Printf("Current LTE Band Preference: 0x%X (has: %v)\n", cur.LTEBandPreference, cur.HasLTEBandPreference)
	}

	pref := qmi.SystemSelectionPreference{
		HasChangeDuration:    true,
		ChangeDuration:       qmi.NASChangeDurationPermanent,
		HasLTEBandPreference: true,
		LTEBandPreference:    0x05, // Band 1 (0x01) + Band 3 (0x04)
	}

	fmt.Println("Applying LTE Band 1+3 preference (0x05)...")
	if err := nas.SetSystemSelectionPreference(ctx, pref); err != nil {
		log.Fatalf("SetSystemSelectionPreference failed: %v", err)
	}
	fmt.Println("Successfully applied system selection preference!")

	after, err := nas.GetSystemSelectionPreference(ctx)
	if err != nil {
		log.Printf("Get after err: %v", err)
	} else {
		fmt.Printf("New LTE Band Preference: 0x%X (has: %v)\n", after.LTEBandPreference, after.HasLTEBandPreference)
	}
}
