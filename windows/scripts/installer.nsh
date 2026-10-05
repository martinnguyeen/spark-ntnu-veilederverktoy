!include "WinVer.nsh"
!include "x64.nsh"

!macro customInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Spark NTNU requires Windows 11 x64."
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastBuild} 22000
    MessageBox MB_OK|MB_ICONSTOP "Spark NTNU requires Windows 11 or newer."
    Abort
  ${EndIf}
!macroend
