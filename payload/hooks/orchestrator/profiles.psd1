@{
    # One entry per orchestration command. Keys are the slash-command names.
    #   Label      - human name used in guard messages, handoff files, and the status line.
    #   Toggle     - whether "<command> on|off|status" may keep the profile active across ordinary prompts.
    #   HeadModel  - substring expected in the session model id while the toggle is on (warning only).
    #   UsagePolicy - 'enforce' blocks protected worker routing on unsafe quota data; 'warn' never blocks.
    #   Workers    - subagent name -> pinned model and tier. The head is tier 0. A caller may dispatch
    #                only to a strictly deeper tier within its own profile; equal or shallower is denied.
    #                HeadOnly marks a worker that only the head (tier 0) may dispatch.
    'fable-orchestrator' = @{
        Label     = 'Fable'
        Toggle    = $false
        HeadModel = 'fable'
        UsagePolicy = 'warn'
        Workers   = @{
            'fable-opus-worker'   = @{ Model = 'opus';   Tier = 1 }
            'fable-sonnet-helper' = @{ Model = 'sonnet'; Tier = 2 }
        }
    }
    'fable-peer' = @{
        Label     = 'Fable Peer'
        Toggle    = $false
        HeadModel = 'fable'
        PeerWorkstreams = $true
        Workers   = @{
            'fable-peer-opus-worker' = @{ Model = 'opus'; Tier = 1 }
        }
    }
    'magnum-opus' = @{
        Label     = 'Magnum Opus'
        Toggle    = $true
        HeadModel = 'opus'
        UsagePolicy = 'warn'
        Workers   = @{
            'magnum-sonnet-worker'   = @{ Model = 'sonnet'; Tier = 1 }
            'magnum-sonnet-reviewer' = @{ Model = 'sonnet'; Tier = 2; HeadOnly = $true }
            'magnum-haiku-scout'     = @{ Model = 'haiku';  Tier = 2 }
        }
    }
}
