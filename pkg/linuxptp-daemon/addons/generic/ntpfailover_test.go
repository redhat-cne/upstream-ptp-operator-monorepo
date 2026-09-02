package generic

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newTestPluginData(gnssFailover bool) *interface{} {
	pluginData := &ntpFailoverPluginData{
		gnssFailover:    gnssFailover,
		pcfsmState:      pcsmsStartupDefault,
		cmdSetEnabled:   make(map[string]func(bool)),
		startupDelay:    90 * time.Second,
		ts2phcTolerance: 5 * time.Second,
		expiryTime:      time.Now().Add(90 * time.Second),
	}
	var iface interface{} = pluginData
	return &iface
}

func TestProcessLogNtpFailover_StartupDisablesChronydEnablesPhc2sys(t *testing.T) {
	data := newTestPluginData(true)
	pluginData := (*data).(*ntpFailoverPluginData)

	var chronydEnabled atomic.Bool
	var phc2sysEnabled atomic.Bool
	var chronydCalls, phc2sysCalls atomic.Int32
	chronydDone := make(chan struct{}, 1)
	phc2sysDone := make(chan struct{}, 1)

	pluginData.cmdSetEnabled[chronydPname] = func(enabled bool) {
		chronydEnabled.Store(enabled)
		if chronydCalls.Add(1) == 1 {
			chronydDone <- struct{}{}
		}
	}
	pluginData.cmdSetEnabled[phc2sysPname] = func(enabled bool) {
		phc2sysEnabled.Store(enabled)
		if phc2sysCalls.Add(1) == 1 {
			phc2sysDone <- struct{}{}
		}
	}

	// Use a non-chronyd line so pcsmsActive does not immediately re-disable chronyd.
	out := processLogNtpFailover(data, ts2phcPname, "ts2phc[123]: nmea delay")
	if out != "ts2phc[123]: nmea delay" {
		t.Fatalf("expected log passthrough, got %q", out)
	}

	select {
	case <-chronydDone:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for chronyd disable")
	}
	select {
	case <-phc2sysDone:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for phc2sys enable")
	}

	if chronydCalls.Load() == 0 || chronydEnabled.Load() {
		t.Fatalf("expected chronyd disabled, calls=%d enabled=%v", chronydCalls.Load(), chronydEnabled.Load())
	}
	if phc2sysCalls.Load() == 0 || !phc2sysEnabled.Load() {
		t.Fatalf("expected phc2sys enabled, calls=%d enabled=%v", phc2sysCalls.Load(), phc2sysEnabled.Load())
	}
	if pluginData.pcfsmState != pcsmsActive {
		t.Fatalf("expected pcsmsActive, got %d", pluginData.pcfsmState)
	}
}

func TestProcessLogNtpFailover_DoesNotBlockOnSyncCallback(t *testing.T) {
	// Simulates the production deadlock: ProcessLog runs on the scanner goroutine
	// and must not wait for a callback that itself waits for the scanner to finish.
	data := newTestPluginData(true)
	pluginData := (*data).(*ntpFailoverPluginData)

	scannerFinished := make(chan struct{})
	callbackStarted := make(chan struct{})

	pluginData.cmdSetEnabled[chronydPname] = func(_ bool) {
		close(callbackStarted)
		// Would deadlock if ProcessLog invoked this synchronously.
		<-scannerFinished
	}
	pluginData.cmdSetEnabled[phc2sysPname] = func(_ bool) {}

	done := make(chan struct{})
	go func() {
		processLogNtpFailover(data, chronydPname, "chronyd starting")
		close(scannerFinished)
		close(done)
	}()

	select {
	case <-callbackStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("callback was never invoked")
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("processLogNtpFailover blocked on enable/disable callback (deadlock)")
	}
}

func TestProcessLogNtpFailover_TryLockExcludesConcurrentDrivers(t *testing.T) {
	data := newTestPluginData(true)
	pluginData := (*data).(*ntpFailoverPluginData)

	var calls atomic.Int32
	pluginData.cmdSetEnabled[chronydPname] = func(_ bool) { calls.Add(1) }
	pluginData.cmdSetEnabled[phc2sysPname] = func(_ bool) { calls.Add(1) }

	// Simulate another goroutine already driving the FSM.
	pluginData.pcfsmMutex.Lock()
	processLogNtpFailover(data, chronydPname, "line-while-locked")
	time.Sleep(50 * time.Millisecond)

	if got := calls.Load(); got != 0 {
		pluginData.pcfsmMutex.Unlock()
		t.Fatalf("expected no enable/disable calls while mutex held, got %d", got)
	}
	if pluginData.pcfsmState != pcsmsStartupDefault {
		pluginData.pcfsmMutex.Unlock()
		t.Fatalf("state should remain default while locked, got %d", pluginData.pcfsmState)
	}
	pluginData.pcfsmMutex.Unlock()

	processLogNtpFailover(data, chronydPname, "line-after-unlock")
	deadline := time.Now().Add(2 * time.Second)
	for calls.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("expected 2 enable/disable calls after unlock, got %d", got)
	}
}

func TestProcessLogNtpFailover_DisabledWhenGnssFailoverFalse(t *testing.T) {
	data := newTestPluginData(false)
	pluginData := (*data).(*ntpFailoverPluginData)

	var called atomic.Bool
	pluginData.cmdSetEnabled[chronydPname] = func(_ bool) { called.Store(true) }
	pluginData.cmdSetEnabled[phc2sysPname] = func(_ bool) { called.Store(true) }

	processLogNtpFailover(data, chronydPname, "chronyd starting")
	time.Sleep(50 * time.Millisecond)

	if called.Load() {
		t.Fatal("callbacks must not run when gnssFailover is false")
	}
	if pluginData.pcfsmState != pcsmsStartupDefault {
		t.Fatalf("state should remain default, got %d", pluginData.pcfsmState)
	}
}

func TestRegisterProcessNtpFailover_OnlyWhenGnssFailover(t *testing.T) {
	data := newTestPluginData(false)
	registerProcessNtpFailover(data, chronydPname, func(bool) {})
	pluginData := (*data).(*ntpFailoverPluginData)
	if _, ok := pluginData.cmdSetEnabled[chronydPname]; ok {
		t.Fatal("should not register callbacks when gnssFailover is false")
	}

	pluginData.gnssFailover = true
	registerProcessNtpFailover(data, chronydPname, func(bool) {})
	if _, ok := pluginData.cmdSetEnabled[chronydPname]; !ok {
		t.Fatal("should register callbacks when gnssFailover is true")
	}
}

func TestInvokeSetEnabled_NilSafe(_ *testing.T) {
	invokeSetEnabled(nil, chronydPname, false)
	data := newTestPluginData(true)
	pluginData := (*data).(*ntpFailoverPluginData)
	invokeSetEnabled(pluginData, chronydPname, false) // no callback registered
}

func TestInvokeSetEnabled_SerializesPerProcess(t *testing.T) {
	data := newTestPluginData(true)
	pluginData := (*data).(*ntpFailoverPluginData)

	started := make(chan struct{})
	release := make(chan struct{})
	var order []bool
	var mu sync.Mutex
	done := make(chan struct{}, 2)

	pluginData.cmdSetEnabled[chronydPname] = func(enabled bool) {
		if !enabled {
			close(started)
			<-release
		}
		mu.Lock()
		order = append(order, enabled)
		mu.Unlock()
		done <- struct{}{}
	}

	invokeSetEnabled(pluginData, chronydPname, false)
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("first callback did not start")
	}
	invokeSetEnabled(pluginData, chronydPname, true)
	close(release)

	for i := 0; i < 2; i++ {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for serialized callbacks")
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(order) != 2 || order[0] || !order[1] {
		t.Fatalf("expected disable then enable in order, got %v", order)
	}
}
