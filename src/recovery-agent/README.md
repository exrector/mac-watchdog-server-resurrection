# Apple Intelligence Recovery Agent

Experimental local macOS recovery agent using Apple's on-device Foundation Models model and a real unrestricted terminal tool.

```sh
swift run recovery-agent selftest
swift run recovery-agent agent "Inspect the Mac and perform a requested repair"
```

The model runs locally. Shell commands run with the privileges of the agent process; a root helper is a separate deployment step.
