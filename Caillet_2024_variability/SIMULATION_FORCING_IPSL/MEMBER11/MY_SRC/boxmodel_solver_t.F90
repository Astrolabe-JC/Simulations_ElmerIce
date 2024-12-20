SUBROUTINE boxmodel_solver( Model,Solver,dt,Transient )
  !------------------------------------------------------------------------------
  !USE CoordinateSystems
  !USE MeshUtils
  USE Netcdf
  USE DefUtils

  IMPLICIT NONE
  !------------------------------------------------------------------------------
  TYPE(Model_t)  :: Model
  TYPE(Solver_t), TARGET :: Solver
  LOGICAL ::  Transient
  REAL(KIND=dp) :: dt

  !------------------------------------------------------------------------------
  !    Local variables
  !------------------------------------------------------------------------------
  CHARACTER(LEN=MAX_NAME_LEN) :: SolverName='MELT_MISMIP'

  TYPE(Mesh_t),POINTER :: Mesh
  TYPE(ValueList_t), POINTER :: Params

  !! variables associated to elements and IPs
  TYPE(Element_t),POINTER ::  Element
  TYPE(Nodes_t),SAVE :: ElementNodes
  TYPE(GaussIntegrationPoints_t) :: IntegStuff
  REAL(kind=dp) :: u, v, w, SqrtElementMetric, s
  REAL(kind=dp),ALLOCATABLE,SAVE :: Basis(:), dBasisdx(:,:)
  INTEGER, POINTER :: NodeIndexes(:)
  INTEGER :: Nmax
  INTEGER :: n

  !! Mandatory variables and associated poiners
  TYPE(Variable_t),POINTER :: BasinVar,BoxVar,MeltVar,GMVar,DepthVar,distGLVar,distIFVar
  REAL(KIND=dp), POINTER ::  Basin(:),Boxnumber(:),Melt(:),GM(:),DepthVal(:),distGL(:),distIF(:)
  INTEGER , POINTER :: BasinPerm(:),BPerm(:),MeltPerm(:),GMPerm(:),DepthPerm(:),distGLPerm(:),distIFPerm(:)
  REAL(kind=dp),ALLOCATABLE :: Depth(:)

  !! Variables related to nc
  INTEGER :: NetcdfStatus,varid,ncid
  CHARACTER(LEN=MAX_NAME_LEN) :: DataFT, DataFS
  INTEGER :: tmeanid, nlen
  INTEGER,SAVE :: nTime
  INTEGER :: nTime2

  INTEGER,SAVE :: VisitedTimes=0, TimeOffset
  INTEGER :: TimePoint
  REAL(KIND=dp) :: Time

  !! Physical Parameters
  REAL(KIND=dp), SAVE :: sealevel, lbd1, lbd2, lbd3, yearinday, meltfac, K, gT,  rhostar, CC,beta, alpha, mskcrit
  INTEGER, SAVE :: boxmax,MaxBas
  LOGICAL :: llGL

  REAL(KIND=dp), DIMENSION(:,:), ALLOCATABLE, SAVE :: S_mean, T_mean
  REAL(KIND=dp), DIMENSION(:,:), ALLOCATABLE,SAVE :: Zbox,Abox,Tbox,Sbox,Mbox
  REAL(KIND=dp), DIMENSION(:), ALLOCATABLE,SAVE :: qqq,T0,S0,basin_Reduced,basinmax, delta_T
  INTEGER , DIMENSION(:), ALLOCATABLE,SAVE :: boxes
  REAL(KIND=dp), DIMENSION(:), ALLOCATABLE,SAVE :: localunity,rr

  REAL(KIND=dp) ::  Integ_Reduced, zzz, tmp1, xbox, Tstar,   &
       &                 Area_Reduced, g1, g2, &
       &                sn, max_Reduced, TT, SS, qqq_Reduced, totalmelt
  REAL(KIND=dp) :: distmax,dmax

  INTEGER ::  e, t,kk, b
  INTEGER :: nD
  INTEGER :: maxbastmp
  INTEGER :: ierr
  INTEGER ::  Indexx

  LOGICAL ::  stat, Found,UnFoundFatal=.TRUE.
  LOGICAL, SAVE :: Firsttime=.TRUE.
  LOGICAL, SAVE :: Parallel

  CHARACTER(len = 200) :: meltValue

  !------------------------------------------------------------------------------
  ! 
  !------------------------------------------------------------------------------
  Params => GetSolverParams()

  Mesh => Model % Mesh

  Nmax = Solver % Mesh % NumberOfNodes

  
  !------------------------------------------------------------------------------
  ! Get mandatory variables
  !------------------------------------------------------------------------------
  BasinVar => VariableGet( Model % Mesh % Variables, 'basins',UnFoundFatal=.TRUE.)
  IF ( BasinVar % TYPE .NE. Variable_on_elements) &
       &   CALL FATAL(SolverName,'basins is not a variable on elements')
  BasinPerm => BasinVar % Perm
  Basin => BasinVar % Values

  BoxVar => VariableGet( Model % Mesh % Variables, 'Boxes',UnFoundFatal=.TRUE.)
  IF ( BoxVar % TYPE .NE. Variable_on_elements) &
       &   CALL FATAL(SolverName,'Boxes is not a variable on elements')
  BPerm => BoxVar % Perm
  Boxnumber  => BoxVar % Values

  MeltVar => VariableGet( Model % Mesh % Variables, 'Melt',UnFoundFatal=.TRUE.)
  IF (MeltVar % TYPE .NE. Variable_on_elements) &
       &   CALL FATAL(SolverName,'Melt is not a variable on elements') 
  MeltPerm => MeltVar % Perm
  Melt => MeltVar % Values

  GMVar => VariableGet( Model % Mesh % Variables, 'GroundedMask',UnFoundFatal=.TRUE.)
  GMPerm => GMVar % Perm
  GM => GMVar % Values

  DepthVar => VariableGet( Model % Mesh % Variables, 'Zb', UnFoundFatal=.TRUE.)
  DepthPerm => DepthVar % Perm
  DepthVal => DepthVar % Values

  distGLVar => VariableGet( Model % Mesh % Variables, 'distGL',UnFoundFatal=.TRUE.)
  distGLPerm => distGLVar % Perm
  distGL => distGLVar % Values

  distIFVar => VariableGet( Model % Mesh % Variables, 'distIF',UnFoundFatal=.TRUE.)
  distIFPerm => distIFVar % Perm
  distIF => distIFVar % Values

  ! Sanity check
  IF (Solver % MeshChanged) &
     CALL FATAL(SolverName,'Mesh has changed not supported ...')

  !------------------------------------------------------------------------------
  ! 1- Initialisation, Read constants and parameters of the simulation :
  !------------------------------------------------------------------------------
  IF (Firsttime) THEN
     Firsttime=.False.

     ! - Grounding line :
     llGL      = ListGetLogical( Params, 'Grounding Line Melt', UnFoundFatal = UnFoundFatal )
     ! - Offset for reading data :
     TimeOffset= ListGetInteger( Params, 'Time Counter start', UnFoundFatal = UnFoundFatal )
     
     !- General :
     sealevel = ListGetCReal( Model % Constants, 'Sea Level', UnFoundFatal = UnFoundFatal )
     lbd1     = ListGetCReal( Model % Constants, 'Liquidus slope', UnFoundFatal = UnFoundFatal )
     lbd2     = ListGetCReal( Model % Constants, 'Liquidus intercept', UnFoundFatal = UnFoundFatal )
     lbd3     = ListGetCReal( Model % Constants, 'Liquidus pressure coeff', UnFoundFatal = UnFoundFatal )
     yearinday= ListGetCReal( Model % Constants, 'Calendar', UnFoundFatal = UnFoundFatal )
     
     ! - PICO : 
     boxmax   = ListGetInteger( Model % Constants, 'Nb Boxes', UnFoundFatal = UnFoundFatal )
     CC       = ListGetCReal( Model % Constants, 'Overturning Coefficient', UnFoundFatal = UnFoundFatal )
     gT       = ListGetCReal( Model % Constants, 'Temperature Exchange Velocity', UnFoundFatal = UnFoundFatal )
     alpha    = ListGetCReal( Model % Constants, 'Thermal Expansion Coefficient EOS', UnFoundFatal = UnFoundFatal )
     beta     = ListGetCReal( Model % Constants, 'Salinity Contraction Coefficient EOS', UnFoundFatal = UnFoundFatal )
     rhostar  = ListGetCReal( Model % Constants, 'In Situ Density EOS', UnFoundFatal = UnFoundFatal )
     meltfac  = ListGetCReal( Model % Constants, 'Melt Factor', UnFoundFatal = UnFoundFatal )     
 
     Parallel = (ParEnv %PEs > 1)

     maxbastmp=MAXVAL(NINT(Basin))
     IF (Parallel) THEN
        CALL MPI_ALLREDUCE(maxbastmp,MaxBas,1,MPI_INTEGER,MPI_MAX,ELMER_COMM_WORLD,ierr)
     ELSE
        MaxBas=maxbastmp
     END IF

     !! Allocate arrays related to PICO
     ALLOCATE( Zbox(boxmax,MaxBas), Abox(boxmax,MaxBas), Tbox(boxmax,MaxBas), Sbox(boxmax,MaxBas), Mbox(boxmax,MaxBas),qqq(MaxBas), T0(MaxBas), S0(MaxBas))
     ALLOCATE(basin_Reduced(MaxBas),basinmax(MaxBas),boxes(MaxBas))

     !! ALLOCATE arrays with mesh dimensions
     ALLOCATE(rr(Solver % NumberOfActiveElements),localunity(Solver % NumberOfActiveElements),Basis(Model % MaxElementNodes), dBasisdx(Model % MaxElementNodes,3))
     Allocate (Depth(SIZE(DepthVal)))


     !!------------------------------------------------------------------------------
     ! Get forcings 
     !!------------------------------------------------------------------------------     

     DataFT = ListGetString( Params, 'data file', Found, UnFoundFatal )
     NetCDFstatus = NF90_OPEN( Trim(DataFT), NF90_NOWRITE, ncid )
     NetCDFstatus = nf90_inq_dimid( ncid, 'number_of_basins' , tmeanid)
     IF (NetCDFstatus /= NF90_NOERR ) THEN
        CALL Fatal(Trim(SolverName), &
           "dim <number_of_basins> not found")
     ENDIF
     NetCDFstatus = nf90_inquire_dimension( ncid, tmeanid , len = nlen )
     IF (nlen.NE.MaxBas) & 
        CALL Fatal(Trim(SolverName),"number of basins do not agree")

     !!! check if we have a time dimension
     NetCDFstatus = nf90_inq_dimid( ncid, 'time' , varid)
     IF (NetCDFstatus.EQ.NF90_NOERR ) THEN
        NetCDFstatus = nf90_inquire_dimension( ncid, varid , len = nTime )
     ELSE
        nTime = 1
     ENDIF
 
     ALLOCATE( T_mean(nlen,nTime) )
     ALLOCATE( S_mean(nlen,nTime) )
     ALLOCATE( delta_T(nlen) ) 
     
     NetCDFstatus = nf90_inq_varid( ncid, 'T_mean', varid)
     NetCDFstatus = nf90_get_var( ncid, varid, T_mean )
     IF ( NetCDFstatus /= NF90_NOERR ) THEN
        CALL Fatal(Trim(SolverName), &
             'Unable to get netcdf variable T_mean')
     END IF

     NetCDFstatus = nf90_inq_varid( ncid, 'S_mean', varid)
     NetCDFstatus = nf90_get_var( ncid, varid, S_mean )
     IF ( NetCDFstatus /= NF90_NOERR ) THEN
        CALL Fatal(Trim(SolverName), &
             'Unable to get netcdf variable S_mean')
     END IF
     
     NetCDFstatus = nf90_inq_varid( ncid, 'delta_T', varid)
     NetCDFstatus = nf90_get_var( ncid, varid, delta_T )
     IF ( NetCDFstatus /= NF90_NOERR ) THEN
        CALL Fatal(Trim(SolverName), &
             'Unable to get netcdf variable delta_T')
     END IF

     ! close file
     NetCDFstatus=nf90_close(ncid)
     
     IF ( llGL ) THEN
        mskcrit =  0.5 ! Melt is at the Grounding Line and floating points
     else
        mskcrit = -0.5 ! No melt at the Grounding Line, only floating points
     ENDif
     CALL INFO(Trim(SolverName),'END FIRST TIME', Level =5)
  END IF
  CALL INFO(Trim(SolverName),'START', Level =5)

  Depth = sealevel - DepthVal     ! Depth < 0 under sea level

  IF (nTime.GT.1) THEN
   ! get time index
      VisitedTimes = VisitedTimes + 1
      IF( ListGetLogical( Params, "Is Time Counter", Found ) ) THEN
       TimePoint = VisitedTimes + TimeOffset
      ELSE
        TimePoint = ListGetInteger( Params, "Time Index", Found )
        IF (.NOT.Found) THEN
          Time = ListGetCReal( Params, "Time Point", Found )
          IF (.NOT.Found) THEN
            Time = GetTime()
            dt = GetTimeStepSize()
            TimePoint = floor((time/yearinday)-(dt/yearinday)/2) + 1 + TimeOffset
          END IF
        END IF
      END IF
      !TimePoint = max(1,min(TimePoint,nTime))
      CALL INFO(Trim(SolverName),"Use Time Index: "//I2S(TimePoint), Level=3)
  ELSE
    TimePoint=1
  ENDIF

  IF (TimePoint.GT.nTime) THEN
        CALL Fatal(Trim(SolverName), &
             'Unable to read the line of T and S in netCDF')
  END IF

  T0(1:MaxBas) = T_mean(1:MaxBas,TimePoint) + delta_T(1:MaxBas)
  IF (VisitedTimes == 1) THEN
   write(*,*) T0(1)
  END IF
  S0(1:MaxBas) = S_mean(1:MaxBas,TimePoint)

  Boxnumber(:)=0.0_dp
  totalmelt=0.0_dp
  Abox(:,:)=0.0_dp
  Zbox(:,:)=0.0_dp
  basinmax(:)=0.0_dp
  distmax = 0.0_dp
  basin_Reduced(:)=0.0_dp
  boxes(:)=0.0_dp
  melt(:)=0.0_dp
  localunity(:) = 0.0_dp
  rr(:)=0.0
  
  CALL INFO(Trim(SolverName),'START BOXES', Level =5)
  ! first loop on element to determine the number of boxes per basins
  DO e=1,Solver % NumberOfActiveElements
     Element => GetActiveElement(e)
     n = GetElementNOFNodes()
     NodeIndexes => Element % NodeIndexes
     Indexx = Element % ElementIndex
     IF ( ANY( GM(GMPerm(NodeIndexes(:))) .GE. mskcrit ) ) CYCLE
     b = NINT(Basin(BasinPerm(Indexx)))

     dmax=MAXVAL(distGL(distGLPerm(NodeIndexes(1:n))))
     IF (basinmax(b) < dmax ) THEN
        basinmax(b)=dmax
     END IF

     dmax= MAXVAL(distGL(distGLPerm(NodeIndexes(1:n))))
     IF (distmax < dmax) THEN
        distmax = dmax
     END IF
  END DO
  IF (Parallel) THEN
     CALL MPI_ALLREDUCE(distmax,max_Reduced,1,MPI_DOUBLE_PRECISION,MPI_MAX,ELMER_COMM_WORLD,ierr)
     distmax= max_Reduced
  END IF
  IF (Parallel) THEN
   CALL MPI_ALLREDUCE(basinmax,basin_Reduced,MaxBas,MPI_DOUBLE_PRECISION,MPI_MAX,ELMER_COMM_WORLD,ierr)
   basinmax(1:MaxBas) = basin_Reduced(1:MaxBas)
  END IF
 
  boxes = 1+NINT(SQRT(basinmax/distmax)*(boxmax-1))

  CALL INFO(TRIM(SolverName),'Boxes DONE', Level =5)
  !- Calculate total area of each box :
  ! second loop on element
  DO e=1,Solver % NumberOfActiveElements
     Element => GetActiveElement(e)
     CALL GetElementNodes( ElementNodes )
     n = GetElementNOFNodes()
     NodeIndexes => Element % NodeIndexes
     Indexx = Element % ElementIndex

     IF ( ANY( GM(GMPerm(NodeIndexes(:))) .GE. mskcrit ) ) CYCLE      ! leave the loop if grounded point in the element
     b= NINT(Basin(BasinPerm(Indexx)))
     nD=boxes(b)
     rr(Indexx) = (SUM(distGL(distGLPerm(NodeIndexes(:))))/MAX(1,SIZE(distGL(distGLPerm(NodeIndexes(:))))))   &
          &             / (SUM( distGL(distGLPerm(NodeIndexes(:)))) / MAX(1,SIZE(distGL(distGLPerm(NodeIndexes(:))))) &
          & + SUM( distIF(distIFPerm(NodeIndexes(:)))) / MAX(1,SIZE(distGL(distGLPerm(NodeIndexes(:))))))
     IntegStuff = GaussPoints( Element )
     DO t=1,IntegStuff % n
        U = IntegStuff % u(t)
        V = IntegStuff % v(t)
        W = IntegStuff % w(t)
        stat = ElementInfo(Element,ElementNodes,U,V,W,SqrtElementMetric, &
             Basis,dBasisdx )
        s = SqrtElementMetric * IntegStuff % s(t)
        localunity(Indexx) = localunity(Indexx) + s * SUM(Basis(1:n))
     END DO
     DO kk=1,nD
        IF ( rr(Indexx) .GT. 1.0-SQRT(1.0*(nD-kk+1)/nD) .AND. rr(Indexx) .LE. 1.0-SQRT(1.0*(nD-kk)/nD) ) THEN
           Abox(kk,b) = Abox(kk,b) + localunity(Indexx)
           Boxnumber(BPerm(Indexx))=kk
        ENDIF
     ENDDO
  END DO


  DO b=1,MaxBas
     nD=boxes(b)
     DO kk=1,nD
        IF (Parallel) THEN
           CALL MPI_ALLREDUCE(Abox(kk,b),Area_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
           Abox(kk,b) = Area_Reduced
        END IF
     ENDDO
  END DO

  ! third loop on element
  Tbox(:,:)=0.d0 ; Sbox(:,:)=0.d0 ; qqq(:)=0.d0
  DO e=1,Solver % NumberOfActiveElements
     Element => GetActiveElement(e)
     n = GetElementNOFNodes()
     NodeIndexes => Element % NodeIndexes
     Indexx = Element % ElementIndex

     IF (  Boxnumber(BPerm(Indexx))==1 ) THEN
        b= NINT(Basin(BasinPerm(Indexx)))
        zzz=SUM(Depth(DepthPerm(NodeIndexes(1:n))))/n !mean depth of an element
        Tstar = lbd1*S0(b) + lbd2 + lbd3*zzz - T0(b)  !NB: Tstar should be < 0
        g1 = gT * Abox(1,b)
        tmp1 = g1 / (CC*rhostar*(beta*S0(b)*meltfac-alpha))
        sn = (0.5*tmp1)**2 - tmp1*Tstar
        ! to avoid negative discriminent (no solution for x otherwise) :
        IF( sn .lt. 0.d0 ) THEN
           xbox = 0.d0
        else
           xbox = - 0.5*tmp1 + SQRT(sn) ! standard solution (Reese et al)
        ENDif
        TT = T0(b) - xbox
        SS = S0(b) - xbox*S0(b)*meltfac
        Tbox(1,b) = Tbox(1,b) + TT * localunity(Indexx)
        Sbox(1,b) = Sbox(1,b) + SS * localunity(Indexx)
        qqq(b) = qqq(b) + CC*rhostar*(beta*(S0(b)-SS)-alpha*(T0(b)-TT)) * localunity(Indexx)
        Melt(MeltPerm(Indexx)) = - gT * meltfac * ( lbd1*SS + lbd2 + lbd3*zzz - TT )
        totalmelt=totalmelt+Melt(MeltPerm(Indexx))* localunity(Indexx)

  END IF

  END DO
  DO b=1,MaxBas
     nD=boxes(b)

     IF (Parallel) THEN
        CALL MPI_ALLREDUCE(Tbox(1,b),Integ_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
        CALL MPI_ALLREDUCE(Sbox(1,b),Area_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
        CALL MPI_ALLREDUCE(qqq(b),qqq_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
        Tbox(1,b) = Integ_Reduced
        Sbox(1,b) = Area_Reduced
        qqq(b) = qqq_Reduced
     END IF
  ENDDO

  Tbox(1,1:MaxBas) = Tbox(1,1:MaxBas) / Abox(1,1:MaxBas)
  Sbox(1,1:MaxBas) = Sbox(1,1:MaxBas) / Abox(1,1:MaxBas)
  qqq(1:MaxBas) = qqq(1:MaxBas) / Abox(1,1:MaxBas)

  !- Temperature and salinity in possible other boxes :
  ! 4 loops on the element
  DO kk=2,boxmax
     DO e=1,Solver % NumberOfActiveElements
        Element => GetActiveElement(e)
        n = GetElementNOFNodes()
        NodeIndexes => Element % NodeIndexes
        Indexx = Element % ElementIndex

        IF (  Boxnumber(BPerm(Indexx))==kk ) THEN
           b= NINT(Basin(BasinPerm(Indexx)))
           zzz = SUM(Depth(DepthPerm(NodeIndexes(1:n))))/n !mean depth of an element
           Tstar = lbd1*Sbox(kk-1,b) + lbd2 + lbd3*zzz - Tbox(kk-1,b)
           g1  = gT * Abox(kk,b)
           g2  = g1 * meltfac
           xbox = - g1 * Tstar / ( qqq(b) + g1 - g2*lbd1*Sbox(kk-1,b) )
           TT = Tbox(kk-1,b) - xbox
           SS = Sbox(kk-1,b) - xbox*Sbox(kk-1,b)*meltfac
           Tbox(kk,b) =  Tbox(kk,b) + TT * localunity(Indexx)
           Sbox(kk,b) =  Sbox(kk,b) + SS * localunity(Indexx)
           Melt(MeltPerm(Indexx)) = - gT * meltfac * ( lbd1*SS + lbd2 + lbd3*zzz - TT )
           totalmelt=totalmelt+Melt(MeltPerm(Indexx))* localunity(Indexx)
        END IF
     END DO
     DO b=1,MaxBas
        nD=boxes(b)
        IF (Parallel) THEN
           CALL MPI_ALLREDUCE(Tbox(kk,b),Integ_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
           CALL MPI_ALLREDUCE(Sbox(kk,b),Area_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
           Tbox(kk,b) = Integ_Reduced
           Sbox(kk,b) = Area_Reduced
        END IF
     ENDDO
     Tbox(kk,1:MaxBas) = Tbox(kk,1:MaxBas) / Abox(kk,1:MaxBas)
     Sbox(kk,1:MaxBas) = Sbox(kk,1:MaxBas) / Abox(kk,1:MaxBas)
  END DO

  IF (Parallel) THEN
     CALL MPI_ALLREDUCE(TotalMelt,Integ_Reduced,1,MPI_DOUBLE_PRECISION,MPI_SUM,ELMER_COMM_WORLD,ierr)
  ELSE
     Integ_Reduced = TotalMelt
  ENDIF
  CALL INFO(SolverName,"----------------------------------------",Level=1)
  WRITE(meltValue,'(F20.3)') Integ_Reduced*917/1.0e12
  Message='PICO INTEGRATED BASAL MELT [Gt/j] (rho=917): '//meltValue 
  CALL INFO(SolverName,Message,Level=1)
  CALL INFO(SolverName,"----------------------------------------",Level=1)

  ! reverse signe for Elmer (loss of mass (ie melt) is negative)
  Melt=-Melt

END SUBROUTINE boxmodel_solver


