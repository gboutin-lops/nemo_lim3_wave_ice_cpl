MODULE limthd_sal
   !!======================================================================
   !!                       ***  MODULE limthd_sal ***
   !! LIM-3 sea-ice :  computation of salinity variations in the ice
   !!======================================================================
   !! History :   -   ! 2003-05 (M. Vancoppenolle) UCL-ASTR first coding for LIM3-1D
   !!            3.0  ! 2005-12 (M. Vancoppenolle) adapted to the 3-D version
   !!            4.0  ! 2011-02 (G. Madec) dynamical allocation
   !!---------------------------------------------------------------------
#if defined key_lim3
   !!----------------------------------------------------------------------
   !!   'key_lim3'                                      LIM-3 sea-ice model
   !!----------------------------------------------------------------------
   !!   lim_thd_sal   : salinity variations in the ice
   !!----------------------------------------------------------------------
   USE par_oce        ! ocean parameters
   USE phycst         ! physical constants (ocean directory)
   USE sbc_oce        ! Surface boundary condition: ocean fields
   USE ice            ! LIM variables
   USE thd_ice        ! LIM thermodynamics
   USE limvar         ! LIM variables
   USE in_out_manager ! I/O manager
   USE lib_mpp        ! MPP library
   USE wrk_nemo       ! work arrays
   USE lib_fortran    ! Fortran utilities (allows no signed zero when 'key_nosignedzero' defined)  

   IMPLICIT NONE
   PRIVATE

   PUBLIC   lim_thd_sal        ! called by limthd module
   PUBLIC   lim_thd_sal_init   ! called by sbc_lim_init

   !!----------------------------------------------------------------------
   !! NEMO/LIM3 4.0 , UCL - NEMO Consortium (2011)
   !! $Id: limthd_sal.F90 7646 2017-02-06 09:25:03Z timgraham $
   !! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE lim_thd_sal( kideb, kiut )
      !!-------------------------------------------------------------------
      !!                ***  ROUTINE lim_thd_sal  ***    
      !!   
      !! ** Purpose :   computes new salinities in the ice
      !!
      !! ** Method  :  3 possibilities
      !!               -> nn_icesal = 1 -> Sice = cst    [ice salinity constant in both time & space] 
      !!               -> nn_icesal = 2 -> Sice = S(z,t) [Vancoppenolle et al. 2005]
      !!               -> nn_icesal = 3 -> Sice = S(z)   [multiyear ice]
      !!---------------------------------------------------------------------
      INTEGER, INTENT(in) ::   kideb, kiut   ! thickness category index
      !
      INTEGER  ::   ii, ij, ji, jk               ! dummy loop indices 
      REAL(wp) ::   iflush, igravdr              ! local scalars
      REAL(wp) ::   zs_sni, zsm_i_gd, zsm_i_fl, zsm_i_si, zsm_i_bg   ! local scalars
      !!---------------------------------------------------------------------

      !--------------------------------------------------------------------|
      ! 1) salinity constant in time                                       |
      !--------------------------------------------------------------------|
      ! do nothing

      !----------------------------------------------------------------------|
      !  2) salinity varying in time                                         |
      !----------------------------------------------------------------------|
      IF(  nn_icesal == 2  ) THEN

         DO ji = kideb, kiut

            ii = MOD( npb(ji) - 1, jpi ) + 1 ; ij = ( npb(ji) - 1 ) / jpi + 1
            !---------------------------------------------------------
            !  Update ice salinity from snow-ice and bottom growth
            !---------------------------------------------------------
            zs_sni   = sss_m(ii,ij) * ( rhoic - rhosn ) * r1_rhoic   ! Salinity of snow ice
            rswitch  = MAX( 0._wp , SIGN( 1._wp , ht_i_1d(ji) - epsi20 ) )
            zsm_i_si = ( zs_sni      - sm_i_1d(ji) ) *             dh_snowice(ji)  / MAX( ht_i_1d(ji), epsi20 ) * rswitch ! snow-ice    
            zsm_i_bg = ( s_i_new(ji) - sm_i_1d(ji) ) * MAX( 0._wp, dh_i_bott(ji) ) / MAX( ht_i_1d(ji), epsi20 ) * rswitch ! bottom growth

            ! Update salinity (nb: salt flux already included in limthd_dh)
            sm_i_1d(ji) = sm_i_1d(ji) + zsm_i_bg + zsm_i_si

            IF( ln_limdS ) THEN
               !---------------------------------------------------------
               !  Update ice salinity from brine drainage and flushing
               !---------------------------------------------------------
               iflush   = MAX( 0._wp , SIGN( 1._wp , t_su_1d(ji) - rt0         ) )  ! =1 if summer 
               igravdr  = MAX( 0._wp , SIGN( 1._wp , t_bo_1d(ji) - t_su_1d(ji) ) )  ! =1 if t_su < t_bo
               zsm_i_gd = - igravdr * MAX( sm_i_1d(ji) - rn_sal_gd , 0._wp ) / rn_time_gd * rdt_ice  ! gravity drainage 
               zsm_i_fl = - iflush  * MAX( sm_i_1d(ji) - rn_sal_fl , 0._wp ) / rn_time_fl * rdt_ice  ! flushing
               
               ! Update salinity   
               sm_i_1d(ji) = sm_i_1d(ji) + zsm_i_fl + zsm_i_gd
               
               ! Salt flux
               sfx_bri_1d(ji) = sfx_bri_1d(ji) - rhoic * a_i_1d(ji) * ht_i_1d(ji) * ( zsm_i_fl + zsm_i_gd ) * r1_rdtice
            ENDIF
         END DO

         ! Salinity profile
         CALL lim_var_salprof1d( kideb, kiut )
         !
      ENDIF 

      !------------------------------------------------------------------------------|
      !  3) vertical profile of salinity, constant in time                           |
      !------------------------------------------------------------------------------|
      IF(  nn_icesal == 3  )   CALL lim_var_salprof1d( kideb, kiut )

      !
   END SUBROUTINE lim_thd_sal


   SUBROUTINE lim_thd_sal_init
      !!-------------------------------------------------------------------
      !!                  ***  ROUTINE lim_thd_sal_init  ***
      !!
      !! ** Purpose :   initialization of ice salinity parameters
      !!
      !! ** Method  :   Read the namicesal namelist and check the parameter
      !!              values called at the first timestep (nit000)
      !!
      !! ** input   :   Namelist namicesal
      !!-------------------------------------------------------------------
      INTEGER  ::   ios                 ! Local integer output status for namelist read
      NAMELIST/namicesal/ ln_limdS, nn_icesal, rn_icesal, rn_sal_gd, rn_time_gd,   &
         &                rn_sal_fl, rn_time_fl, rn_simax, rn_simin 
      !!-------------------------------------------------------------------
      !
      REWIND( numnam_ice_ref )              ! Namelist namicesal in reference namelist : Ice salinity
      READ  ( numnam_ice_ref, namicesal, IOSTAT = ios, ERR = 901)
901   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namicesal in reference namelist', lwp )

      REWIND( numnam_ice_cfg )              ! Namelist namicesal in configuration namelist : Ice salinity
      READ  ( numnam_ice_cfg, namicesal, IOSTAT = ios, ERR = 902 )
902   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namicesal in configuration namelist', lwp )
      IF(lwm) WRITE ( numoni, namicesal )
      !
      IF(lwp) THEN                           ! control print
         WRITE(numout,*)
         WRITE(numout,*) 'lim_thd_sal_init : Ice parameters for salinity '
         WRITE(numout,*) '~~~~~~~~~~~~~~~~'
         WRITE(numout,*) '   activate gravity drainage and flushing (T) or not (F)   ln_limdS   = ', ln_limdS
         WRITE(numout,*) '   switch for salinity                                     nn_icesal  = ', nn_icesal
         WRITE(numout,*) '   bulk salinity value if nn_icesal = 1                    rn_icesal  = ', rn_icesal
         WRITE(numout,*) '   restoring salinity for gravity drainage                 rn_sal_gd  = ', rn_sal_gd
         WRITE(numout,*) '   restoring time for for gravity drainage                 rn_time_gd = ', rn_time_gd
         WRITE(numout,*) '   restoring salinity for flushing                         rn_sal_fl  = ', rn_sal_fl
         WRITE(numout,*) '   restoring time for flushing                             rn_time_fl = ', rn_time_fl
         WRITE(numout,*) '   Maximum tolerated ice salinity                          rn_simax   = ', rn_simax
         WRITE(numout,*) '   Minimum tolerated ice salinity                          rn_simin   = ', rn_simin
      ENDIF
      !
   END SUBROUTINE lim_thd_sal_init

#else
   !!----------------------------------------------------------------------
   !!   Default option         Dummy Module          No LIM-3 sea-ice model
   !!----------------------------------------------------------------------
#endif
   !!======================================================================
END MODULE limthd_sal
