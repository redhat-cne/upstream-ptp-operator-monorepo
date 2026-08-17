package ptphelper

import (
	"regexp"
	"testing"

	ptpv1 "github.com/k8snetworkplumbingwg/ptp-operator/api/v1"
	"github.com/k8snetworkplumbingwg/ptp-operator/test/pkg"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestProfileNameMatchPattern(t *testing.T) {
	pattern := ProfileNameMatchPattern("temp", "temp")
	re, err := regexp.Compile(`#profile:\s*` + pattern)
	if err != nil {
		t.Fatalf("compile pattern: %v", err)
	}

	if !re.MatchString("#profile: temp") {
		t.Errorf("pattern %q should match unqualified profile", pattern)
	}
	if !re.MatchString("#profile: temp_temp") {
		t.Errorf("pattern %q should match qualified profile", pattern)
	}
	if re.MatchString("#profile: other") {
		t.Errorf("pattern %q should not match unrelated profile", pattern)
	}
}

func TestGetProfileName(t *testing.T) {
	t.Run("returns CR profile name without qualifying", func(t *testing.T) {
		profileName := pkg.PtpTempPolicyName
		config := &ptpv1.PtpConfig{
			ObjectMeta: metav1.ObjectMeta{Name: pkg.PtpTempPolicyName},
			Spec: ptpv1.PtpConfigSpec{
				Profile: []ptpv1.PtpProfile{{Name: &profileName}},
			},
		}

		got, err := GetProfileName(config, true)
		if err != nil {
			t.Fatalf("GetProfileName: %v", err)
		}
		if got != pkg.PtpTempPolicyName {
			t.Errorf("GetProfileName() = %q, want %q", got, pkg.PtpTempPolicyName)
		}
	})

	t.Run("receiverOnly skips tbc-tt", func(t *testing.T) {
		tt := "tbc-tt"
		tr := "tbc-tr"
		config := &ptpv1.PtpConfig{
			ObjectMeta: metav1.ObjectMeta{Name: pkg.PTPWPCTBCPolicyName},
			Spec: ptpv1.PtpConfigSpec{
				Profile: []ptpv1.PtpProfile{
					{Name: &tt},
					{Name: &tr},
				},
			},
		}

		got, err := GetProfileName(config, true)
		if err != nil {
			t.Fatalf("GetProfileName: %v", err)
		}
		if got != "tbc-tr" {
			t.Errorf("GetProfileName() = %q, want %q", got, "tbc-tr")
		}
	})
}
