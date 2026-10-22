"""Development-only LLDB helper: fill this app's pairing form from its private file.

No network request, no credential extraction, no raw screen or field value output.
The caller uses an existing signed Debug build and an explicitly selected device/PID.
"""
import json
import time
from pathlib import Path


def run(debugger, proof_path, preflight=True):
    import lldb

    process = debugger.GetSelectedTarget().GetProcess()
    deadline = time.monotonic() + 20
    try:
        while process.GetState() != lldb.eStateStopped:
            if process.GetState() in (lldb.eStateExited, lldb.eStateDetached):
                raise RuntimeError("target exited or detached during attach")
            if time.monotonic() >= deadline:
                raise RuntimeError("device attach did not stop within budget")
            time.sleep(0.1)
            process = debugger.GetSelectedTarget().GetProcess()
        if process.GetState() != lldb.eStateStopped:
            raise RuntimeError("target is not stopped for UI prefill")
        if process.GetTarget().GetExecutable().GetFilename() != "AgentInbox":
            raise RuntimeError("unexpected target executable")
        main = next((t for t in process if t.GetQueueName() == "com.apple.main-thread"), None)
        if main is None:
            raise RuntimeError("main UI thread not established")
        process.SetSelectedThread(main)
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetIgnoreBreakpoints(True)
        options.SetUnwindOnError(True)
        options.SetTimeoutInMicroSeconds(15000000)
        options.SetSuppressPersistentResult(True)
        frame = main.GetFrameAtIndex(0)
        for module in ("UIKit", "Foundation"):
            command = lldb.SBCommandReturnObject()
            debugger.GetCommandInterpreter().HandleCommand("expression -l objc++ -- @import " + module, command)
            if not command.Succeeded():
                raise RuntimeError("framework import failed: " + module + ": " + command.GetError())
        expression = r'''({
          BOOL preflight = PREFLIGHT_FLAG;
          BOOL ok = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"dev.matianyi.agentinbox"];
          UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
          UIWindow *window = [scene.windows firstObject];
          NSMutableArray *views = [NSMutableArray arrayWithObject:window];
          for (NSUInteger i=0; i<[views count] && i<2048; i++) {
            UIView *v=(UIView *)[views objectAtIndex:i]; [views addObjectsFromArray:v.subviews];
          }
          UITextField *codeField=nil; UITextField *urlField=nil;
          NSUInteger codes=0; NSUInteger urls=0;
          for (UIView *v in views) {
            if ([v isKindOfClass:[UITextField class]]) {
              UITextField *f=(UITextField *)v;
              if ([f.placeholder isEqualToString:@"一次性配对码"]) { codeField=f; codes++; }
              if ([f.placeholder isEqualToString:@"服务地址"]) { urlField=f; urls++; }
            }
          }
          ok = ok && codes==1 && urls==1;
          if (ok) {
            NSURL *documents=[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
            NSURL *source=[documents URLByAppendingPathComponent:@"agentinbox-phone-prefill.txt"];
            NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:source.path error:nil];
            NSString *fileType=(NSString *)[attributes objectForKey:NSFileType];
            NSNumber *fileSize=(NSNumber *)[attributes objectForKey:NSFileSize];
            NSNumber *fileMode=(NSNumber *)[attributes objectForKey:NSFilePosixPermissions];
            ok = [fileType isEqualToString:NSFileTypeRegular] && [fileSize unsignedIntegerValue]<=128 && ([fileMode unsignedIntegerValue]&0777)==0600;
            if (ok) {
              NSString *value=[NSString stringWithContentsOfURL:source encoding:NSUTF8StringEncoding error:nil];
              value=[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
              ok = value.length==32 && [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:value]];
              if (ok) ok = [[NSFileManager defaultManager] removeItemAtURL:source error:nil];
              if (ok) {
                [urlField setText:@"https://relay.example.ts.net:8443"];
                [urlField sendActionsForControlEvents:UIControlEventEditingChanged];
                [codeField setText:value]; [codeField sendActionsForControlEvents:UIControlEventEditingChanged];
                ok = codeField.text.length==32;
                if (preflight) { [codeField setText:@""]; [codeField sendActionsForControlEvents:UIControlEventEditingChanged]; ok=ok && codeField.text.length==0; }
              }
            }
          }
          ok;
        })'''.replace("PREFLIGHT_FLAG", "YES" if preflight else "NO")
        result = frame.EvaluateExpression(expression, options)
        if result.GetError().Fail():
            # Source contains paths and selectors only; never include the field or file value.
            raise RuntimeError("form expression failed: " + str(result.GetError()))
        if result.GetValue() not in ("true", "YES", "1"):
            raise RuntimeError("form or private-file validation refused")
        proof = {"pid": process.GetProcessID(), "target": "dev.matianyi.agentinbox",
                 "preflightPublicDummyOnly": preflight, "privateAppFileConsumedAndDeleted": True,
                 "fieldFilledThroughEditingChanged": True, "dummyCleared": preflight,
                 "networkSubmissionPerformed": False, "rawCodeKeyOrScreenPrinted": False}
        Path(proof_path).write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof))
    finally:
        if process.IsValid() and process.GetState() not in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
            error = process.Detach()
            if error.Fail():
                print("AgentInbox detach needs attention")
