package main

import "testing"

func TestCustomDERPRegion(t *testing.T) {
	region, err := customDERPRegion("derp.remotecode.io", "82.25.69.175", 444, 3478, 1)
	if err != nil {
		t.Fatal(err)
	}
	if region.RegionID != 1 || len(region.Nodes) != 1 {
		t.Fatalf("unexpected region: %#v", region)
	}
	node := region.Nodes[0]
	if node.RegionID != 1 || node.HostName != "derp.remotecode.io" || node.IPv4 != "82.25.69.175" || node.DERPPort != 444 || node.STUNPort != 3478 {
		t.Fatalf("unexpected DERP node: %#v", node)
	}
}

func TestCustomDERPRegionRejectsWrongRegionAndInvalidAddress(t *testing.T) {
	for _, test := range []struct {
		name     string
		host     string
		ipv4     string
		regionID uint32
	}{
		{name: "public region", host: "derp.remotecode.io", ipv4: "82.25.69.175", regionID: 301},
		{name: "invalid host", host: "https://derp.remotecode.io", ipv4: "82.25.69.175", regionID: 1},
		{name: "invalid IPv4", host: "derp.remotecode.io", ipv4: "not-an-ip", regionID: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := customDERPRegion(test.host, test.ipv4, 444, 3478, test.regionID); err == nil {
				t.Fatal("expected invalid DERP configuration")
			}
		})
	}
}

func TestParseAllowedRejectsEmptyAndAcceptsSnapshot(t *testing.T) {
	if _, err := parseAllowed("[]"); err == nil {
		t.Fatal("expected empty allowlist rejection")
	}
	allowed, err := parseAllowed(`["nodekey:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","nodekey:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]`)
	if err != nil {
		t.Fatal(err)
	}
	if len(allowed) != 2 {
		t.Fatalf("got %d allowed clients, want 2", len(allowed))
	}
}

func TestTailcatTargetPortIsIndependentFromSwiftLoopbackPort(t *testing.T) {
	const swiftLoopbackPort uint16 = 45123
	if !acceptsTailcatTargetPort(18217) {
		t.Fatal("frozen Tailcat service port 18217 must be accepted")
	}
	if acceptsTailcatTargetPort(swiftLoopbackPort) {
		t.Fatal("ephemeral Swift forwarding port must not become the Tailcat service port")
	}
}
