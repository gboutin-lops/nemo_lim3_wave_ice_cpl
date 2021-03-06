MODULE sao_intp
   !!======================================================================
   !!                    ***  MODULE sao_intp ***
   !! ** Purpose : Run NEMO observation operator in offline mode
   !!======================================================================
   !! History :  3.6  ! 2015-12  (A. Ryan)  Original code
   !!----------------------------------------------------------------------
   !        ! NEMO modules
   USE in_out_manager
   USE diaobs
   !        ! Stand Alone Observation operator modules
   USE sao_read
   USE sao_data

   IMPLICIT NONE
   PRIVATE

   PUBLIC sao_interp

   !!----------------------------------------------------------------------
   !! NEMO/OPA 3.7 , NEMO Consortium (2015)
   !! $Id: trazdf_imp.F90 6140 2015-12-21 11:35:23Z timgraham $
   !! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE sao_interp
      !!----------------------------------------------------------------------
      !!                    ***  SUBROUTINE sao_interp ***
      !!
      !! ** Purpose : To interpolate the model as if it were running online.
      !!
      !! ** Method : 1. Populate model counterparts
      !!             2. Call dia_obs at appropriate time steps
      !!----------------------------------------------------------------------
      INTEGER ::   istp    ! time step index
      INTEGER ::   ifile   ! file index
      !!----------------------------------------------------------------------
      istp = nit000 - 1
      nstop = 0
      ifile = 1
      CALL sao_rea_dri(ifile)
      !
      DO WHILE ( istp <= nitend .AND. nstop == 0 )
         IF (ifile <= n_files + 1) THEN
            IF ( MOD(istp, nn_sao_freq) == nit000 ) THEN
               CALL sao_rea_dri(ifile)
               ifile = ifile + 1
            ENDIF
            CALL dia_obs(istp)
         ENDIF
         istp = istp + 1
      END DO
      !
   END SUBROUTINE sao_interp

   !!======================================================================
END MODULE sao_intp
