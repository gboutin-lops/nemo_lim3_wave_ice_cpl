MODULE sao_data
   !!======================================================================
   !!                       ***  MODULE sao_data  ***
   !!======================================================================
   !! History :  3.6  ! 2015-12  (A. Ryan)  Original code
   !!----------------------------------------------------------------------
   USE par_kind, ONLY: lc
   USE lib_mpp         ! distributed memory computing
   USE in_out_manager

   IMPLICIT NONE

   INTEGER, PARAMETER :: MaxNumFiles = 1000

   !! Stand Alone Observation operator settings
   CHARACTER(len=lc) ::   sao_files(MaxNumFiles)   !: model files
   INTEGER           ::   n_files                  !: number of files
   INTEGER           :: nn_sao_idx(MaxNumFiles)    !: time_counter indices
   INTEGER           :: nn_sao_freq                !: read frequency in time steps
   
   !!----------------------------------------------------------------------
   !! NEMO/OPA 3.7 , NEMO Consortium (2015)
   !! $Id: trazdf_imp.F90 6140 2015-12-21 11:35:23Z timgraham $
   !! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE sao_data_init()
      !!----------------------------------------------------------------------
      !!                    ***  SUBROUTINE sao_data_init ***
      !!
      !! ** Purpose : To read namelists and initialise offline_oper run.
      !!
      !!----------------------------------------------------------------------
      INTEGER ::   jf                   ! file dummy loop index
      LOGICAL ::   lmask(MaxNumFiles)   ! Logical mask used for counting
      INTEGER ::   ios
      !!
      NAMELIST/namsao/sao_files, nn_sao_idx, nn_sao_freq
      !!----------------------------------------------------------------------

      ! Standard offline obs_oper initialisation
      n_files = 0                   ! number of files to cycle through
      sao_files(:) = ''             ! list of files to read in
      nn_sao_idx(:) = 0             ! list of indices inside each file
      nn_sao_freq = -1              ! input frequency in time steps

      ! Standard offline obs_oper settings
      REWIND( numnam_ref )              ! Namelist namctl in reference namelist : Control prints & Benchmark
      READ  ( numnam_ref, namsao, IOSTAT = ios, ERR = 901 )
901   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namsao in reference namelist', .TRUE. )
      !
      REWIND( numnam_cfg )              ! Namelist namctl in confguration namelist : Control prints & Benchmark
      READ  ( numnam_cfg, namsao, IOSTAT = ios, ERR = 902 )
902   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namsao in configuration namelist', .TRUE. )
     
      lmask(:) = .FALSE.               ! count input files
      WHERE (sao_files(:) /= '') lmask(:) = .TRUE.
      n_files = COUNT(lmask)
      !
      IF(nn_sao_freq == -1) THEN      ! Initialise sub obs window frequency
         nn_sao_freq = nitend - nit000 + 1      ! Run length
      ENDIF
      !
      IF(lwp) THEN                     ! Print summary of settings
         WRITE(numout,*)
         WRITE(numout,*) 'offline obs_oper : Initialization'
         WRITE(numout,*) '~~~~~~~~~~~~~~~~~'
         WRITE(numout,*) '   Namelist namsao : set stand alone obs_oper parameters'
         DO jf = 1, n_files
            WRITE(numout,'(1X,2A)') '   Input forecast file name          forecastfile = ', TRIM(sao_files(jf))
            WRITE(numout,*) '   Input forecast file index        forecastindex = ', nn_sao_idx(jf)
         END DO
      END IF
      !
   END SUBROUTINE sao_data_init

   !!======================================================================
END MODULE sao_data

