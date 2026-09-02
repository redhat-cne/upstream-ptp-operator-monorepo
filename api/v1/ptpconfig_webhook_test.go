package v1

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestPtpConfigValidator_MinOffsetThresholdAccepted(t *testing.T) {
	profileName := "test-profile"
	ptpConfig := &PtpConfig{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-ptpconfig",
			Namespace: "openshift-ptp",
		},
		Spec: PtpConfigSpec{
			Profile: []PtpProfile{
				{
					Name: &profileName,
					PtpClockThreshold: &PtpClockThreshold{
						HoldOverTimeout:    5,
						MaxOffsetThreshold: 100,
						MinOffsetThreshold: -100,
					},
				},
			},
		},
	}

	validator := &ptpConfigValidator{}
	ctx := context.Background()

	warnings, err := validator.ValidateCreate(ctx, ptpConfig)
	assert.NoError(t, err)
	assert.Empty(t, warnings)

	warnings, err = validator.ValidateUpdate(ctx, ptpConfig, ptpConfig)
	assert.NoError(t, err)
	assert.Empty(t, warnings)
}

func newTestPtpConfigWithSettings(settings map[string]string) *PtpConfig {
	profileName := "test-profile"
	return &PtpConfig{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-ptpconfig",
			Namespace: "openshift-ptp",
		},
		Spec: PtpConfigSpec{
			Profile: []PtpProfile{
				{
					Name:        &profileName,
					PtpSettings: settings,
				},
			},
		},
	}
}

func TestPtpConfigValidator_SysOffsetThreshold(t *testing.T) {
	validator := &ptpConfigValidator{}
	ctx := context.Background()

	tests := []struct {
		name        string
		value       string
		expectError bool
	}{
		{name: "valid sysOffsetThreshold accepted", value: "200", expectError: false},
		{name: "non-numeric sysOffsetThreshold rejected", value: "abc", expectError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ptpConfig := newTestPtpConfigWithSettings(map[string]string{"sysOffsetThreshold": tt.value})

			warnings, err := validator.ValidateCreate(ctx, ptpConfig)
			if tt.expectError {
				assert.Error(t, err)
				assert.Contains(t, err.Error(), "sysOffsetThreshold")
				assert.Contains(t, err.Error(), "must be an unsigned integer")
			} else {
				assert.NoError(t, err)
				assert.Empty(t, warnings)
			}

			warnings, err = validator.ValidateUpdate(ctx, ptpConfig, ptpConfig)
			if tt.expectError {
				assert.Error(t, err)
				assert.Contains(t, err.Error(), "sysOffsetThreshold")
				assert.Contains(t, err.Error(), "must be an unsigned integer")
			} else {
				assert.NoError(t, err)
				assert.Empty(t, warnings)
			}
		})
	}
}

func TestPtpConfigValidator_SysOffsetSamples(t *testing.T) {
	validator := &ptpConfigValidator{}
	ctx := context.Background()
	sampleKeys := []string{"sysOffsetInSyncSamples", "sysOffsetOutOfSyncSamples"}

	for _, sampleKey := range sampleKeys {
		t.Run(sampleKey+" accepted independently", func(t *testing.T) {
			ptpConfig := newTestPtpConfigWithSettings(map[string]string{sampleKey: "10"})

			warnings, err := validator.ValidateCreate(ctx, ptpConfig)
			assert.NoError(t, err)
			assert.Empty(t, warnings)
			assert.Equal(t, "10", ptpConfig.Spec.Profile[0].PtpSettings[sampleKey])
		})
	}

	tests := []struct {
		name  string
		value string
	}{
		{name: "negative value rejected", value: "-5"},
		{name: "fractional value rejected", value: "3.5"},
		{name: "non-numeric value rejected", value: "abc"},
	}

	for _, sampleKey := range sampleKeys {
		for _, tt := range tests {
			t.Run(sampleKey+" "+tt.name, func(t *testing.T) {
				ptpConfig := newTestPtpConfigWithSettings(map[string]string{sampleKey: tt.value})

				_, err := validator.ValidateCreate(ctx, ptpConfig)
				assert.Error(t, err)
				assert.Contains(t, err.Error(), sampleKey)
				assert.Contains(t, err.Error(), "must be an unsigned integer")
			})
		}
	}
}

func TestPtpConfigValidator_SysOffsetSettings_RejectsInvalidUpdate(t *testing.T) {
	validator := &ptpConfigValidator{}
	ctx := context.Background()

	oldConfig := newTestPtpConfigWithSettings(map[string]string{"sysOffsetOutOfSyncSamples": "10"})
	newConfig := newTestPtpConfigWithSettings(map[string]string{"sysOffsetOutOfSyncSamples": "abc"})

	_, err := validator.ValidateUpdate(ctx, oldConfig, newConfig)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "sysOffsetOutOfSyncSamples")
	assert.Contains(t, err.Error(), "must be an unsigned integer")
}

func TestPtpConfigValidator_ExistingProfilesUnaffected(t *testing.T) {
	validator := &ptpConfigValidator{}
	ctx := context.Background()

	t.Run("nil PtpSettings accepted", func(t *testing.T) {
		ptpConfig := newTestPtpConfigWithSettings(nil)

		warnings, err := validator.ValidateCreate(ctx, ptpConfig)
		assert.NoError(t, err)
		assert.Empty(t, warnings)
	})

	t.Run("pre-existing key without sysOffset* keys accepted", func(t *testing.T) {
		ptpConfig := newTestPtpConfigWithSettings(map[string]string{"inSyncConditionThreshold": "500"})

		warnings, err := validator.ValidateCreate(ctx, ptpConfig)
		assert.NoError(t, err)
		assert.Empty(t, warnings)
	})
}
