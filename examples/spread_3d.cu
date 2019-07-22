#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <complex>
#include "../src/cufinufft.h"
#include "../src/spreadinterp.h"
#include "../finufft/utils.h"

using namespace std;

int main(int argc, char* argv[])
{
	int nf1, nf2, nf3;
	FLT sigma = 2.0;
	int N1, N2, N3, M;
	if (argc<6) {
		fprintf(stderr,
			"Usage: spread3d [method [nupts_distr [N1 N2 [M [tol [Horner]]]]]]\n");
		fprintf(stderr,"Details --\n");
		fprintf(stderr,"method 1: input driven without sorting\n");
		fprintf(stderr,"method 5: subprob\n");
		return 1;
	}  
	double w;
	int method;
	sscanf(argv[1],"%d",&method);
	int nupts_distribute;
	sscanf(argv[2],"%d",&nupts_distribute);
	sscanf(argv[3],"%lf",&w); nf1 = (int)w;  // so can read 1e6 right!
	sscanf(argv[4],"%lf",&w); nf2 = (int)w;  // so can read 1e6 right!
	sscanf(argv[5],"%lf",&w); nf3 = (int)w;  // so can read 1e6 right!

	int maxsubprobsize=1024;
	if(argc>6){
		sscanf(argv[6],"%d",&maxsubprobsize);
	}
	N1 = (int) nf1/sigma*2;
	N2 = (int) nf2/sigma*2;
	N3 = (int) nf3/sigma*2;
	M = N1*N2*N3;// let density always be 1
	if(argc>7){
		sscanf(argv[7],"%lf",&w); M  = (int)w;  // so can read 1e6 right!
		//if(M == 0) M=N1*N2;
	}

	FLT tol=1e-6;
	if(argc>8){
		sscanf(argv[8],"%lf",&w); tol  = (FLT)w;  // so can read 1e6 right!
	}

	int Horner=0;
	if(argc>9){
		sscanf(argv[9],"%d",&Horner);
	}

	int ier;

	int ns=std::ceil(-log10(tol/10.0));
	cufinufft_opts opts;
	cufinufft_plan dplan;
	FLT upsampfac=2.0;

	ier = cufinufft_default_opts(opts,tol,upsampfac);
	if(ier != 0 ){
		cout<<"error: cufinufft_default_opts"<<endl;
		return 0;
	}
	opts.method=method;
	cout<<scientific<<setprecision(3);


	FLT *x, *y, *z;
	CPX *c, *fw;
	cudaMallocHost(&x, M*sizeof(FLT));
	cudaMallocHost(&y, M*sizeof(FLT));
	cudaMallocHost(&z, M*sizeof(FLT));
	cudaMallocHost(&c, M*sizeof(CPX));
	cudaMallocHost(&fw,nf1*nf2*nf3*sizeof(CPX));

	opts.rescaled=1;
	opts.Horner=Horner;
	switch(nupts_distribute){
		// Making data
		case 1: //uniform
			{
				x[0] = 0;
				y[0] = 0;
				z[0] = 2;
				for (int i = 0; i < M; i++) {
					x[i] = x[0];//RESCALE(M_PI*randm11(), nf1, 1);
					y[i] = y[0];//RESCALE(M_PI*randm11(), nf2, 1);
					z[i] = z[0];//RESCALE(M_PI*randm11(), nf3, 1);
					c[i].real() = randm11();
					c[i].imag() = randm11();
				}
			}
			break;
		case 2: // concentrate on a small region
			{
				for (int i = 0; i < M; i++) {
					x[i] = RESCALE(M_PI*rand01()/(nf1*2/8), nf1, 1);
					y[i] = RESCALE(M_PI*rand01()/(nf2*2/8), nf2, 1);
					z[i] = RESCALE(M_PI*rand01()/(nf3*2/8), nf3, 1);
					c[i].real() = randm11();
					c[i].imag() = randm11();
				}
			}
			break;
		case 3:
			{
				for (int i = 0; i < M; i++) {
					x[i] = RESCALE(M_PI*randm11(), nf1, 1);
					y[i] = RESCALE(M_PI*randm11(), nf2, 1);
					z[i] = RESCALE(M_PI*randm11(), nf3, 1);
					c[i].real() = randm11();
					c[i].imag() = randm11();
					cout << x[i] <<","<<y[i]<<","<<z[i]<<endl;
				}
			}
			break;
		case 4:
			{
				for(int k=0; k<nf3; k++){
					for(int j=0; j<nf2; j++){
						for(int i=0; i<nf1; i++){
							int idx = i+j*nf1+k*nf1*nf2;
							if(idx <= M){
								x[idx] = i;
								y[idx] = j;
								z[idx] = k;
							}
						}
					}
				}
				for (int i = 0; i < M; i++) {
					c[i].real() = randm11();
					c[i].imag() = randm11();
				}
			}
			break;
	}

	CNTime timer;
	/*warm up gpu*/
	char *a;
	timer.restart();
	checkCudaErrors(cudaMalloc(&a,1));
#ifdef TIME
	cout<<"[time  ]"<< " (warm up) First cudamalloc call " << timer.elapsedsec() 
		<<" s"<<endl<<endl;
#endif

#ifdef INFO
	cout<<"[info  ] Spreading "<<M<<" pts to ["<<nf1<<"x"<<nf2<<"] uniform grids"
		<<endl;
#endif

	if(opts.method==1 || opts.method == 2 || opts.method==3)
	{
		opts.bin_size_x=4;
		opts.bin_size_y=4;
		opts.bin_size_z=4;
		opts.o_bin_size_x=8;
		opts.o_bin_size_y=8;
		opts.o_bin_size_z=8;
		opts.maxsubprobsize=maxsubprobsize;
	}
	if(opts.method == 5)
	{
		opts.bin_size_x=16;
		opts.bin_size_y=16;
		opts.bin_size_z=2;
		opts.maxsubprobsize=maxsubprobsize;
	}

	timer.restart();
	ier = cufinufft_spread3d(N1, N2, N3, nf1, nf2, nf3, fw, M, x, y, z, c, 
		opts, &dplan);
	if(ier != 0 ){
		cout<<"error: cnufftspread3d"<<endl;
		return 0;
	}
	FLT t=timer.elapsedsec();
	printf("[Method %d] %ld NU pts to #%d U pts in %.3g s (\t%.3g NU pts/s)\n",
			opts.method,M,nf1*nf2*nf3,t,M/t);
#if 0
	cout<<"[result-input]"<<endl;
	for(int k=0; k<nf3; k++){
		for(int j=0; j<nf2; j++){
			//if( j % opts.bin_size_y == 0)
			//	printf("\n");
			for (int i=0; i<nf1; i++){
				if( i % opts.bin_size_x == 0 && i!=0)
					printf(" |");
				printf(" (%2.3g,%2.3g)",fw[i+j*nf1+k*nf2*nf1].real(),
					fw[i+j*nf1+k*nf2*nf1].imag() );
			}
			cout<<endl;
		}
		cout<<"----------------------------------------------------------------"<<endl;
	}
#endif

	cudaDeviceReset();
	cudaFreeHost(x);
	cudaFreeHost(y);
	cudaFreeHost(c);
	cudaFreeHost(fw);
	return 0;
}