MODULE diaar5
!!======================================================================
!!                       ***  MODULE  diaar5  ***
!! AR5 diagnostics
!!======================================================================
!! History :  3.2  !  2009-11  (S. Masson)  Original code
!!            3.3  !  2010-10  (C. Ethe, G. Madec) reorganisation of initialisation phase + merge TRC-TRA
!!----------------------------------------------------------------------
!!   dia_ar5       : AR5 diagnostics
!!   dia_ar5_init  : initialisation of AR5 diagnostics
!!----------------------------------------------------------------------
   USE oce            ! ocean dynamics and active tracers
   USE dom_oce        ! ocean space and time domain
   USE eosbn2         ! equation of state                (eos_bn2 routine)
   USE lib_mpp        ! distribued memory computing library
   USE iom            ! I/O manager library
   USE timing         ! preformance summary
   USE wrk_nemo       ! working arrays
   USE fldread        ! type FLD_N
   USE phycst         ! physical constant
   USE in_out_manager  ! I/O manager
   USE zdfddm
   USE zdf_oce

   IMPLICIT NONE
   PRIVATE

   PUBLIC   dia_ar5        ! routine called in step.F90 module
   PUBLIC   dia_ar5_alloc  ! routine called in nemogcm.F90 module
   PUBLIC   dia_ar5_hst    ! heat/salt transport

   REAL(wp)                         ::   vol0         ! ocean volume (interior domain)
   REAL(wp)                         ::   area_tot     ! total ocean surface (interior domain)
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:  ) ::   area         ! cell surface (interior domain)
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:  ) ::   thick0       ! ocean thickness (interior domain)
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:,:) ::   sn0          ! initial salinity

   LOGICAL  :: l_ar5
      
!! * Substitutions
!!----------------------------------------------------------------------
!!                    *** zdfddm_substitute.h90  ***
!!----------------------------------------------------------------------
!! ** purpose :   substitute fsaht. the eddy diffusivity coeff.
!!      with a constant or 1D or 2D or 3D array, using CPP macro.
!!----------------------------------------------------------------------

!   Defautl option :                     avs = avt


!!----------------------------------------------------------------------
!! NEMO/OPA 4.0 , NEMO Consortium (2011)
!! $Id: zdfddm_substitute.h90 4152 2013-11-05 11:59:53Z cetlod $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
!!----------------------------------------------------------------------
!!                   ***  vectopt_loop_substitute  ***
!!----------------------------------------------------------------------
!! ** purpose :   substitute the inner loop start/end indices with CPP macro
!!                allow unrolling of do-loop (useful with vector processors)
!!----------------------------------------------------------------------
!!----------------------------------------------------------------------
!! NEMO/OPA 3.7 , NEMO Consortium (2014)
!! $Id: vectopt_loop_substitute.h90 4990 2014-12-15 16:42:49Z timgraham $
!! Software governed by the CeCILL licence (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------




!!----------------------------------------------------------------------
!! NEMO/OPA 3.3 , NEMO Consortium (2010)
!! $Id: diaar5.F90 7753 2017-03-03 11:46:59Z mocavero $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
CONTAINS

   FUNCTION dia_ar5_alloc()
!!----------------------------------------------------------------------
!!                    ***  ROUTINE dia_ar5_alloc  ***
!!----------------------------------------------------------------------
      INTEGER :: dia_ar5_alloc
!!----------------------------------------------------------------------
!
      ALLOCATE( area(jpi,jpj), thick0(jpi,jpj) , sn0(jpi,jpj,jpk) , STAT=dia_ar5_alloc )
!
      IF( lk_mpp             )   CALL mpp_sum ( dia_ar5_alloc )
      IF( dia_ar5_alloc /= 0 )   CALL ctl_warn('dia_ar5_alloc: failed to allocate arrays')
!
   END FUNCTION dia_ar5_alloc


   SUBROUTINE dia_ar5( kt )
!!----------------------------------------------------------------------
!!                    ***  ROUTINE dia_ar5  ***
!!
!! ** Purpose :   compute and output some AR5 diagnostics
!!----------------------------------------------------------------------
!
      INTEGER, INTENT( in ) ::   kt   ! ocean time-step index
!
      INTEGER  ::   ji, jj, jk                      ! dummy loop arguments
      REAL(wp) ::   zvolssh, zvol, zssh_steric, zztmp, zarho, ztemp, zsal, zmass
      REAL(wp) ::   zaw, zbw, zrw
!
      REAL(wp), POINTER, DIMENSION(:,:)     :: zarea_ssh , zbotpres       ! 2D workspace
      REAL(wp), POINTER, DIMENSION(:,:)     :: zpe                         ! 2D workspace
      REAL(wp), POINTER, DIMENSION(:,:,:)   :: zrhd , zrhop               ! 3D workspace
      REAL(wp), POINTER, DIMENSION(:,:,:,:) :: ztsn                       ! 4D workspace
!!--------------------------------------------------------------------
      IF( nn_timing == 1 )   CALL timing_start('dia_ar5')
 
      IF( kt == nit000 )     CALL dia_ar5_init

      IF( l_ar5 ) THEN
         CALL wrk_alloc( jpi , jpj              , zarea_ssh , zbotpres )
         CALL wrk_alloc( jpi , jpj , jpk        , zrhd      , zrhop    )
         CALL wrk_alloc( jpi , jpj , jpk , jpts , ztsn                 )
         zarea_ssh(:,:) = area(:,:) * sshn(:,:)
      ENDIF
!
      IF( iom_use( 'voltot' ) .OR. iom_use( 'sshtot' )  .OR. iom_use( 'sshdyn' )  ) THEN    
!                                         ! total volume of liquid seawater
         zvolssh = SUM( zarea_ssh(:,:) ) 
         IF( lk_mpp )   CALL mpp_sum( zvolssh )
         zvol = vol0 + zvolssh
      
         CALL iom_put( 'voltot', zvol               )
         CALL iom_put( 'sshtot', zvolssh / area_tot )
         CALL iom_put( 'sshdyn', sshn(:,:) - (zvolssh / area_tot) )
!
      ENDIF

      IF( iom_use( 'botpres' ) .OR. iom_use( 'sshthster' )  .OR. iom_use( 'sshsteric' )  ) THEN    
!
         ztsn(:,:,:,jp_tem) = tsn(:,:,:,jp_tem)                    ! thermosteric ssh
         ztsn(:,:,:,jp_sal) = sn0(:,:,:)
         CALL eos( ztsn, zrhd, gdept_n(:,:,:) )                       ! now in situ density using initial salinity
!
         zbotpres(:,:) = 0._wp                        ! no atmospheric surface pressure, levitating sea-ice
         DO jk = 1, jpkm1
            zbotpres(:,:) = zbotpres(:,:) + e3t_n(:,:,jk) * zrhd(:,:,jk)
         END DO
         IF( ln_linssh ) THEN
            IF( ln_isfcav ) THEN
               DO ji = 1, jpi
                  DO jj = 1, jpj
                     zbotpres(ji,jj) = zbotpres(ji,jj) + sshn(ji,jj) * zrhd(ji,jj,mikt(ji,jj)) + riceload(ji,jj)
                  END DO
               END DO
            ELSE
               zbotpres(:,:) = zbotpres(:,:) + sshn(:,:) * zrhd(:,:,1)
            END IF
!!gm
!!gm   riceload should be added in both ln_linssh=T or F, no?
!!gm
         END IF
!
         zarho = SUM( area(:,:) * zbotpres(:,:) ) 
         IF( lk_mpp )   CALL mpp_sum( zarho )
         zssh_steric = - zarho / area_tot
         CALL iom_put( 'sshthster', zssh_steric )
      
!                                         ! steric sea surface height
         CALL eos( tsn, zrhd, zrhop, gdept_n(:,:,:) )                 ! now in situ and potential density
         zrhop(:,:,jpk) = 0._wp
         CALL iom_put( 'rhop', zrhop )
!
         zbotpres(:,:) = 0._wp                        ! no atmospheric surface pressure, levitating sea-ice
         DO jk = 1, jpkm1
            zbotpres(:,:) = zbotpres(:,:) + e3t_n(:,:,jk) * zrhd(:,:,jk)
         END DO
         IF( ln_linssh ) THEN
            IF ( ln_isfcav ) THEN
               DO ji = 1,jpi
                  DO jj = 1,jpj
                     zbotpres(ji,jj) = zbotpres(ji,jj) + sshn(ji,jj) * zrhd(ji,jj,mikt(ji,jj)) + riceload(ji,jj)
                  END DO
               END DO
            ELSE
               zbotpres(:,:) = zbotpres(:,:) + sshn(:,:) * zrhd(:,:,1)
            END IF
         END IF
!
         zarho = SUM( area(:,:) * zbotpres(:,:) ) 
         IF( lk_mpp )   CALL mpp_sum( zarho )
         zssh_steric = - zarho / area_tot
         CALL iom_put( 'sshsteric', zssh_steric )
      
!                                         ! ocean bottom pressure
         zztmp = rau0 * grav * 1.e-4_wp               ! recover pressure from pressure anomaly and cover to dbar = 1.e4 Pa
         zbotpres(:,:) = zztmp * ( zbotpres(:,:) + sshn(:,:) + thick0(:,:) )
         CALL iom_put( 'botpres', zbotpres )
!
      ENDIF

      IF( iom_use( 'masstot' ) .OR. iom_use( 'temptot' )  .OR. iom_use( 'saltot' )  ) THEN    
!                                         ! Mean density anomalie, temperature and salinity
         ztemp = 0._wp
         zsal  = 0._wp
         DO jk = 1, jpkm1
            DO jj = 1, jpj
               DO ji = 1, jpi
                  zztmp = area(ji,jj) * e3t_n(ji,jj,jk)
                  ztemp = ztemp + zztmp * tsn(ji,jj,jk,jp_tem)
                  zsal  = zsal  + zztmp * tsn(ji,jj,jk,jp_sal)
               END DO
            END DO
         END DO
         IF( ln_linssh ) THEN
            IF( ln_isfcav ) THEN
               DO ji = 1, jpi
                  DO jj = 1, jpj
                     ztemp = ztemp + zarea_ssh(ji,jj) * tsn(ji,jj,mikt(ji,jj),jp_tem) 
                     zsal  = zsal  + zarea_ssh(ji,jj) * tsn(ji,jj,mikt(ji,jj),jp_sal) 
                  END DO
               END DO
            ELSE
               ztemp = ztemp + SUM( zarea_ssh(:,:) * tsn(:,:,1,jp_tem) )
               zsal  = zsal  + SUM( zarea_ssh(:,:) * tsn(:,:,1,jp_sal) )
            END IF
         ENDIF
         IF( lk_mpp ) THEN  
            CALL mpp_sum( ztemp )
            CALL mpp_sum( zsal  )
         END IF
!
         zmass = rau0 * ( zarho + zvol )                 ! total mass of liquid seawater
         ztemp = ztemp / zvol                            ! potential temperature in liquid seawater
         zsal  = zsal  / zvol                            ! Salinity of liquid seawater
!
         CALL iom_put( 'masstot', zmass )
         CALL iom_put( 'temptot', ztemp )
         CALL iom_put( 'saltot' , zsal  )
!
      ENDIF

      IF( iom_use( 'tnpeo' )) THEN    
! Work done against stratification by vertical mixing
! Exclude points where rn2 is negative as convection kicks in here and
! work is not being done against stratification
          CALL wrk_alloc( jpi, jpj, zpe )
          zpe(:,:) = 0._wp
          IF( lk_zdfddm ) THEN
             DO ji=1,jpi
                DO jj=1,jpj
                   DO jk=1,jpk
                      zrw =   ( gdepw_n(ji,jj,jk  ) - gdept_n(ji,jj,jk) )   &
                         &  / ( gdept_n(ji,jj,jk-1) - gdept_n(ji,jj,jk) )
!
                      zaw = rab_n(ji,jj,jk,jp_tem) * (1. - zrw) + rab_n(ji,jj,jk-1,jp_tem)* zrw
                      zbw = rab_n(ji,jj,jk,jp_sal) * (1. - zrw) + rab_n(ji,jj,jk-1,jp_sal)* zrw
!
                      zpe(ji, jj) = zpe(ji, jj) - MIN(0._wp, rn2(ji,jj,jk)) * &
                           &       grav * (avt(ji,jj,jk) * zaw * (tsn(ji,jj,jk-1,jp_tem) - tsn(ji,jj,jk,jp_tem) )  &
                           &       - avt(ji,jj,jk) * zbw * (tsn(ji,jj,jk-1,jp_sal) - tsn(ji,jj,jk,jp_sal) ) )

                   ENDDO
                ENDDO
             ENDDO
          ELSE
             DO ji = 1, jpi
                DO jj = 1, jpj
                   DO jk = 1, jpk
                       zpe(ji,jj) = zpe(ji,jj) + avt(ji, jj, jk) * MIN(0._wp,rn2(ji, jj, jk)) * rau0 * e3w_n(ji, jj, jk)
                   ENDDO
                ENDDO
             ENDDO
          ENDIF
          CALL lbc_lnk( zpe, 'T', 1._wp)         
          CALL iom_put( 'tnpeo', zpe )
          CALL wrk_dealloc( jpi, jpj, zpe )
      ENDIF
!
      IF( l_ar5 ) THEN
        CALL wrk_dealloc( jpi , jpj              , zarea_ssh , zbotpres )
        CALL wrk_dealloc( jpi , jpj , jpk        , zrhd      , zrhop    )
        CALL wrk_dealloc( jpi , jpj , jpk , jpts , ztsn                 )
      ENDIF
!
      IF( nn_timing == 1 )   CALL timing_stop('dia_ar5')
!
   END SUBROUTINE dia_ar5

   SUBROUTINE dia_ar5_hst( ktra, cptr, pua, pva ) 
!!----------------------------------------------------------------------
!!                    ***  ROUTINE dia_ar5_htr ***
!!----------------------------------------------------------------------
!! Wrapper for heat transport calculations
!! Called from all advection and/or diffusion routines
!!----------------------------------------------------------------------
      INTEGER                         , INTENT(in )  :: ktra  ! tracer index
      CHARACTER(len=3)                , INTENT(in)   :: cptr  ! transport type  'adv'/'ldf'
      REAL(wp), DIMENSION(jpi,jpj,jpk), INTENT(in)   :: pua   ! 3D input array of advection/diffusion
      REAL(wp), DIMENSION(jpi,jpj,jpk), INTENT(in)   :: pva   ! 3D input array of advection/diffusion
!
      INTEGER    ::  ji, jj, jk
      REAL(wp), POINTER, DIMENSION(:,:)  :: z2d

    

      CALL wrk_alloc( jpi, jpj, z2d )
      z2d(:,:) = pua(:,:,1) 
      DO jk = 1, jpkm1
         DO jj = 2, jpjm1
            DO ji = 2, jpim1   ! vector opt.
               z2d(ji,jj) = z2d(ji,jj) + pua(ji,jj,jk) 
            END DO
         END DO
       END DO
       CALL lbc_lnk( z2d, 'U', -1. )
       IF( cptr == 'adv' ) THEN
          IF( ktra == jp_tem ) CALL iom_put( "uadv_heattr" , rau0_rcp * z2d )  ! advective heat transport in i-direction
          IF( ktra == jp_sal ) CALL iom_put( "uadv_salttr" , rau0     * z2d )  ! advective salt transport in i-direction
       ENDIF
       IF( cptr == 'ldf' ) THEN
          IF( ktra == jp_tem ) CALL iom_put( "udiff_heattr" , rau0_rcp * z2d ) ! diffusive heat transport in i-direction
          IF( ktra == jp_sal ) CALL iom_put( "udiff_salttr" , rau0     * z2d ) ! diffusive salt transport in i-direction
       ENDIF
!
       z2d(:,:) = pva(:,:,1) 
       DO jk = 1, jpkm1
          DO jj = 2, jpjm1
             DO ji = 2, jpim1   ! vector opt.
                z2d(ji,jj) = z2d(ji,jj) + pva(ji,jj,jk) 
             END DO
          END DO
       END DO
       CALL lbc_lnk( z2d, 'V', -1. )
       IF( cptr == 'adv' ) THEN
          IF( ktra == jp_tem ) CALL iom_put( "vadv_heattr" , rau0_rcp * z2d )  ! advective heat transport in j-direction
          IF( ktra == jp_sal ) CALL iom_put( "vadv_salttr" , rau0     * z2d )  ! advective salt transport in j-direction
       ENDIF
       IF( cptr == 'ldf' ) THEN
          IF( ktra == jp_tem ) CALL iom_put( "vdiff_heattr" , rau0_rcp * z2d ) ! diffusive heat transport in j-direction
          IF( ktra == jp_sal ) CALL iom_put( "vdiff_salttr" , rau0     * z2d ) ! diffusive salt transport in j-direction
       ENDIF
          
       CALL wrk_dealloc( jpi, jpj, z2d )

   END SUBROUTINE dia_ar5_hst


   SUBROUTINE dia_ar5_init
!!----------------------------------------------------------------------
!!                  ***  ROUTINE dia_ar5_init  ***
!!
!! ** Purpose :   initialization for AR5 diagnostic computation
!!----------------------------------------------------------------------
      INTEGER  ::   inum
      INTEGER  ::   ik
      INTEGER  ::   ji, jj, jk  ! dummy loop indices
      REAL(wp) ::   zztmp  
      REAL(wp), POINTER, DIMENSION(:,:,:,:) ::   zsaldta   ! Jan/Dec levitus salinity
!
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )   CALL timing_start('dia_ar5_init')
!
      l_ar5 = .FALSE.
      IF(   iom_use( 'voltot'  ) .OR. iom_use( 'sshtot'    )  .OR. iom_use( 'sshdyn' )  .OR.  & 
         &  iom_use( 'masstot' ) .OR. iom_use( 'temptot'   )  .OR. iom_use( 'saltot' ) .OR.  &    
         &  iom_use( 'botpres' ) .OR. iom_use( 'sshthster' )  .OR. iom_use( 'sshsteric' )  ) L_ar5 = .TRUE.
  
      IF( l_ar5 ) THEN
!
         CALL wrk_alloc( jpi , jpj , jpk, jpts, zsaldta )
!                                      ! allocate dia_ar5 arrays
         IF( dia_ar5_alloc() /= 0 )   CALL ctl_stop( 'STOP', 'dia_ar5_init : unable to allocate arrays' )

         area(:,:) = e1e2t(:,:) * tmask_i(:,:)

         area_tot = SUM( area(:,:) )   ;   IF( lk_mpp )   CALL mpp_sum( area_tot )

         vol0        = 0._wp
         thick0(:,:) = 0._wp
         DO jk = 1, jpkm1
            vol0        = vol0        + SUM( area (:,:) * tmask(:,:,jk) * e3t_0(:,:,jk) )
            thick0(:,:) = thick0(:,:) +    tmask_i(:,:) * tmask(:,:,jk) * e3t_0(:,:,jk)
         END DO
         IF( lk_mpp )   CALL mpp_sum( vol0 )

         CALL iom_open ( 'sali_ref_clim_monthly', inum )
         CALL iom_get  ( inum, jpdom_data, 'vosaline' , zsaldta(:,:,:,1), 1  )
         CALL iom_get  ( inum, jpdom_data, 'vosaline' , zsaldta(:,:,:,2), 12 )
         CALL iom_close( inum )

         sn0(:,:,:) = 0.5_wp * ( zsaldta(:,:,:,1) + zsaldta(:,:,:,2) )        
         sn0(:,:,:) = sn0(:,:,:) * tmask(:,:,:)
         IF( ln_zps ) THEN               ! z-coord. partial steps
            DO jj = 1, jpj               ! interpolation of salinity at the last ocean level (i.e. the partial step)
               DO ji = 1, jpi
                  ik = mbkt(ji,jj)
                  IF( ik > 1 ) THEN
                     zztmp = ( gdept_1d(ik) - gdept_0(ji,jj,ik) ) / ( gdept_1d(ik) - gdept_1d(ik-1) )
                     sn0(ji,jj,ik) = ( 1._wp - zztmp ) * sn0(ji,jj,ik) + zztmp * sn0(ji,jj,ik-1)
                  ENDIF
               END DO
            END DO
         ENDIF
!
         CALL wrk_dealloc( jpi , jpj , jpk, jpts, zsaldta )
!
      ENDIF
!
      IF( nn_timing == 1 )   CALL timing_stop('dia_ar5_init')
!
   END SUBROUTINE dia_ar5_init

!!======================================================================
END MODULE diaar5
