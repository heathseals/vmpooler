require 'spec_helper'
require 'time'
require 'mock_redis'

describe 'Pool Manager' do
  let(:logger) { MockLogger.new }
  let(:redis) { MockRedis.new }
  let(:metrics) { Vmpooler::DummyStatsd.new }
  let(:config) { {} }
  let(:pool) { 'pool1' }
  let(:vm) { 'vm1' }
  let(:timeout) { 5 }
  let(:host) { double('host') }
  let(:token) { 'token1234'}

  subject { Vmpooler::PoolManager.new(config, logger, redis, metrics) }

  describe '#check_pending_vm' do
    let(:vsphere) { double('vsphere') }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _check_pending_vm' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_check_pending_vm).with(vm,pool,timeout,vsphere)

      subject.check_pending_vm(vm, pool, timeout, vsphere)
    end
  end

  describe '#open_socket' do
    let(:TCPSocket) { double('tcpsocket') }
    let(:socket) { double('tcpsocket') }
    let(:hostname) { 'host' }
    let(:domain) { 'domain.local'}
    let(:default_socket) { 22 }

    before do
      expect(subject).not_to be_nil
      allow(socket).to receive(:close)
    end

    it 'opens socket with defaults' do
      expect(TCPSocket).to receive(:new).with(hostname,default_socket).and_return(socket)

      expect(subject.open_socket(hostname)).to eq(nil)
    end

    it 'yields the socket if a block is given' do
      expect(TCPSocket).to receive(:new).with(hostname,default_socket).and_return(socket)

      expect{ |socket| subject.open_socket(hostname,nil,nil,default_socket,&socket) }.to yield_control.exactly(1).times 
    end

    it 'closes the opened socket' do
      expect(TCPSocket).to receive(:new).with(hostname,default_socket).and_return(socket)
      expect(socket).to receive(:close)

      expect(subject.open_socket(hostname)).to eq(nil)
    end

    it 'opens a specific socket' do
      expect(TCPSocket).to receive(:new).with(hostname,80).and_return(socket)

      expect(subject.open_socket(hostname,nil,nil,80)).to eq(nil)
    end

    it 'uses a specific domain with the hostname' do
      expect(TCPSocket).to receive(:new).with("#{hostname}.#{domain}",default_socket).and_return(socket)

      expect(subject.open_socket(hostname,domain)).to eq(nil)
    end

    it 'raises error if host is not resolvable' do
      expect(TCPSocket).to receive(:new).with(hostname,default_socket).and_raise(SocketError,'getaddrinfo: No such host is known')

      expect { subject.open_socket(hostname,nil,1) }.to raise_error(SocketError)
    end

    it 'raises error if socket is not listening' do
      expect(TCPSocket).to receive(:new).with(hostname,default_socket).and_raise(SocketError,'No connection could be made because the target machine actively refused it')

      expect { subject.open_socket(hostname,nil,1) }.to raise_error(SocketError)
    end
  end

  describe '#_check_pending_vm' do
    let(:vsphere) { double('vsphere') }

    before do
      expect(subject).not_to be_nil
    end

    context 'host does not exist or not in pool' do
      it 'calls fail_pending_vm' do
        expect(vsphere).to receive(:find_vm).and_return(nil)
        expect(subject).to receive(:fail_pending_vm).with(vm, pool, timeout, false) 

        subject._check_pending_vm(vm, pool, timeout, vsphere)
      end
    end

    context 'host is in pool' do
      it 'calls move_pending_vm_to_ready if host is ready' do
        expect(vsphere).to receive(:find_vm).and_return(host)
        expect(subject).to receive(:open_socket).and_return(nil)
        expect(subject).to receive(:move_pending_vm_to_ready).with(vm, pool, host)

        subject._check_pending_vm(vm, pool, timeout, vsphere)
      end

      it 'calls fail_pending_vm if an error is raised' do
        expect(vsphere).to receive(:find_vm).and_return(host)
        expect(subject).to receive(:open_socket).and_raise(SocketError,'getaddrinfo: No such host is known')
        expect(subject).to receive(:fail_pending_vm).with(vm, pool, timeout)

        subject._check_pending_vm(vm, pool, timeout, vsphere)
      end
    end
  end

  describe '#remove_nonexistent_vm' do
    before do
      expect(subject).not_to be_nil
    end

    it 'removes VM from pending in redis' do
      create_pending_vm(pool,vm)

      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
      subject.remove_nonexistent_vm(vm, pool)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
    end

    it 'logs msg' do
      expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' no longer exists. Removing from pending.")

      subject.remove_nonexistent_vm(vm, pool)
    end
  end

 describe '#fail_pending_vm' do
    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_pending_vm(pool,vm)
    end

    it 'takes no action if VM is not cloning' do
      expect(subject.fail_pending_vm(vm, pool, timeout)).to eq(nil)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
    end

    it 'takes no action if VM is within timeout' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Time.now.to_s)
      expect(subject.fail_pending_vm(vm, pool, timeout)).to eq(nil)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
    end

    it 'moves VM to completed queue if VM has exceeded timeout and exists' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(nil)
      expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
      expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
    end

    it 'logs message if VM has exceeded timeout and exists' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' marked as 'failed' after #{timeout} minutes")
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(nil)
    end

    it 'calls remove_nonexistent_vm if VM has exceeded timeout and does not exist' do
      redis.hset("vmpooler__vm__#{vm}", 'clone',Date.new(2001,1,1).to_s)
      expect(subject).to receive(:remove_nonexistent_vm).with(vm, pool)
      expect(subject.fail_pending_vm(vm, pool, timeout,false)).to eq(nil)
    end

    it 'swallows error if an error is raised' do
      redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
      expect(subject.fail_pending_vm(vm, pool, timeout,true)).to eq(nil)
    end

    it 'logs message if an error is raised' do
      redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
      expect(logger).to receive(:log).with('d', String)

      subject.fail_pending_vm(vm, pool, timeout,true)
    end
  end
  
  describe '#move_pending_vm_to_ready' do
    before do
      expect(subject).not_to be_nil
      allow(Socket).to receive(:getaddrinfo)
    end

    before(:each) do
      create_pending_vm(pool,vm)
    end

    context 'when hostname does not match VM name' do
      it 'should not take any action' do
        expect(logger).to receive(:log).exactly(0).times
        expect(Socket).to receive(:getaddrinfo).exactly(0).times

        allow(host).to receive(:summary).and_return( double('summary') )
        allow(host).to receive_message_chain(:summary, :guest).and_return( double('guest') )
        allow(host).to receive_message_chain(:summary, :guest, :hostName).and_return ('different_name')

        subject.move_pending_vm_to_ready(vm, pool, host)
      end
    end

    context 'when hostname matches VM name' do
      before do
        allow(host).to receive(:summary).and_return( double('summary') )
        allow(host).to receive_message_chain(:summary, :guest).and_return( double('guest') )
        allow(host).to receive_message_chain(:summary, :guest, :hostName).and_return (vm)
      end

      it 'should move the VM from pending to ready pool' do
        expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(true)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.sismember("vmpooler__pending__#{pool}", vm)).to be(false)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[>] [#{pool}] '#{vm}' moved to 'ready' queue")

        subject.move_pending_vm_to_ready(vm, pool, host)
      end

      it 'should set the boot time in redis' do
        redis.hset("vmpooler__vm__#{vm}", 'clone',Time.now.to_s)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to be_nil
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to_not be_nil
        # TODO Should we inspect the value to see if it's valid?
      end

      it 'should not determine boot timespan if clone start time not set' do
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to be_nil
        subject.move_pending_vm_to_ready(vm, pool, host)
        expect(redis.hget('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm)).to eq("") # Possible implementation bug here. Should still be nil here
      end

      it 'should raise error if clone start time is not parsable' do
        redis.hset("vmpooler__vm__#{vm}", 'clone','iamnotparsable_asdate')
        expect{subject.move_pending_vm_to_ready(vm, pool, host)}.to raise_error(/iamnotparsable_asdate/)
      end
    end
  end

  describe '#check_ready_vm' do
    let(:vsphere) { double('vsphere') }
    let(:ttl) { 0 }

    let(:config) {
      YAML.load(<<-EOT
---
:config:
  vm_checktime: 15

EOT
      )
    }

    before(:each) do
      expect(Thread).to receive(:new).and_yield
      create_ready_vm(pool,vm)
    end

    it 'should raise an error if a TTL above zero is specified' do
      expect { subject.check_ready_vm(vm,pool,5,vsphere) }.to raise_error(NameError) # This is an implementation bug
    end

    context 'a VM that does not need to be checked' do
      it 'should do nothing' do
        redis.hset("vmpooler__vm__#{vm}", 'check',Time.now.to_s)
        subject.check_ready_vm(vm, pool, ttl, vsphere)
      end
    end

    context 'a VM that does not exist' do
      before do
        allow(vsphere).to receive(:find_vm).and_return(nil)
      end

      it 'should set the current check timestamp' do
        allow(subject).to receive(:open_socket)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to be_nil
        subject.check_ready_vm(vm, pool, ttl, vsphere)
        expect(redis.hget("vmpooler__vm__#{vm}", 'check')).to_not be_nil
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[!] [#{pool}] '#{vm}' not found in vCenter inventory, removed from 'ready' queue")
        allow(subject).to receive(:open_socket)
        subject.check_ready_vm(vm, pool, ttl, vsphere)
      end

      it 'should remove the VM from the ready queue' do
        allow(subject).to receive(:open_socket)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
        subject.check_ready_vm(vm, pool, ttl, vsphere)
        expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
      end
    end

    context 'a VM that needs to be checked' do
      before(:each) do
        redis.hset("vmpooler__vm__#{vm}", 'check',Date.new(2001,1,1).to_s)

        allow(host).to receive(:summary).and_return( double('summary') )
        allow(host).to receive_message_chain(:summary, :guest).and_return( double('guest') )
        allow(host).to receive_message_chain(:summary, :guest, :hostName).and_return (vm)
        
        allow(vsphere).to receive(:find_vm).and_return(host)
      end

      context 'and is ready' do
        before(:each) do
          allow(host).to receive(:runtime).and_return( double('runtime') )
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOn')
          allow(host).to receive_message_chain(:summary, :guest, :hostName).and_return (vm)
          allow(subject).to receive(:open_socket).with(vm).and_return(nil)
        end

        it 'should only set the next check interval' do
          subject.check_ready_vm(vm, pool, ttl, vsphere)
        end
      end

      context 'but turned off and name mismatch' do
        before(:each) do
          allow(host).to receive(:runtime).and_return( double('runtime') )
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOff')
          allow(host).to receive_message_chain(:summary, :guest, :hostName).and_return ('')
          allow(subject).to receive(:open_socket).with(vm).and_raise(SocketError,'getaddrinfo: No such host is known')
        end

        it 'should move the VM to the completed queue multiple times' do
          # There is an implementation bug which attempts the move multiple times
          expect(redis).to receive(:smove).with("vmpooler__ready__#{pool}", "vmpooler__completed__#{pool}", vm).at_least(2).times

          subject.check_ready_vm(vm, pool, ttl, vsphere)
        end

        it 'should move the VM to the completed queue' do
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(true)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
          subject.check_ready_vm(vm, pool, ttl, vsphere)
          expect(redis.sismember("vmpooler__ready__#{pool}", vm)).to be(false)
          expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
        end

        it 'should log messages about being powered off, name mismatch and removed from ready queue' do
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' appears to be powered off, removed from 'ready' queue")
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' has mismatched hostname, removed from 'ready' queue")

         # There is an implementation bug which attempts the move multiple times however
         # as the VM is no longer in the ready queue, redis also throws an error
         expect(logger).to receive(:log).with("d", "[!] [#{pool}] '#{vm}' is unreachable, and failed to remove from 'ready' queue")

          subject.check_ready_vm(vm, pool, ttl, vsphere)
        end

        it 'should log a message if it fails to move queues' do
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' appears to be powered off, removed from 'ready' queue")
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' has mismatched hostname, removed from 'ready' queue")
          expect(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' is unreachable, and failed to remove from 'ready' queue")

          subject.check_ready_vm(vm, pool, ttl, vsphere)
        end
      end
    end
  end

  describe '#check_running_vm' do
    let(:vsphere) { double('vsphere') }
    let (:ttl) { 5 }

    before do
      expect(subject).not_to be_nil
    end

    it 'calls _check_running_vm' do
      expect(Thread).to receive(:new).and_yield
      expect(subject).to receive(:_check_running_vm).with(vm, pool, ttl, vsphere)

      subject.check_running_vm(vm, pool, ttl, vsphere)
    end
  end

  describe '#_check_running_vm' do
    let(:vsphere) { double('vsphere') }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_running_vm(pool,vm)
    end

    it 'does nothing with a missing VM' do
      allow(vsphere).to receive(:find_vm).and_return(nil)
      expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      subject._check_running_vm(vm, pool, timeout, vsphere)
      expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
    end

    context 'valid host' do
      let(:vm_host) { double('vmhost') }

     it 'should not move VM when not poweredOn' do
        # I'm not sure this test is useful.  There is no codepath
        # in _check_running_vm that looks at Power State
        allow(vsphere).to receive(:find_vm).and_return vm_host
        allow(vm_host).to receive(:runtime).and_return true
        allow(vm_host).to receive_message_chain(:runtime, :powerState).and_return 'poweredOff'
        expect(logger).not_to receive(:log).with('d', "[!] [#{pool}] '#{vm}' appears to be powered off or dead")
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, timeout, vsphere)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should not move VM if it has no checkout time' do
        allow(vsphere).to receive(:find_vm).and_return vm_host
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, 0, vsphere)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should not move VM if TTL is zero' do
        allow(vsphere).to receive(:find_vm).and_return vm_host
        redis.hset("vmpooler__active__#{pool}", vm,(Time.now - timeout*60*60).to_s)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        subject._check_running_vm(vm, pool, 0, vsphere)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
      end

      it 'should move VM when past TTL' do
        allow(vsphere).to receive(:find_vm).and_return vm_host
        redis.hset("vmpooler__active__#{pool}", vm,(Time.now - timeout*60*60).to_s)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(true)
        expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(false)
        subject._check_running_vm(vm, pool, timeout, vsphere)
        expect(redis.sismember("vmpooler__running__#{pool}", vm)).to be(false)
        expect(redis.sismember("vmpooler__completed__#{pool}", vm)).to be(true)
      end
    end
  end

  describe '#move_vm_queue' do
    let(:queue_from) { 'pending' }
    let(:queue_to) { 'completed' }
    let(:message) { 'message' }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      create_pending_vm(pool, vm, token)
    end

    it 'VM should be in the "from queue" before the move' do
      expect(redis.sismember("vmpooler__#{queue_from}__#{pool}",vm))
    end

    it 'VM should not be in the "from queue" after the move' do
      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
      expect(!redis.sismember("vmpooler__#{queue_from}__#{pool}",vm))
    end

    it 'VM should not be in the "to queue" before the move' do
      expect(!redis.sismember("vmpooler__#{queue_to}__#{pool}",vm))
    end

    it 'VM should be in the "to queue" after the move' do
      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
      expect(redis.sismember("vmpooler__#{queue_to}__#{pool}",vm))
    end

    it 'should log a message' do
      allow(logger).to receive(:log).with('d', "[!] [#{pool}] '#{vm}' #{message}")

      subject.move_vm_queue(pool, vm, queue_from, queue_to, message)
    end
  end

  describe '#move_running_to_completed' do
    before do
      expect(subject).not_to be_nil
    end

    it 'uses the pool in smove' do
      allow(redis).to receive(:smove).with(String, String, String)
      allow(logger).to receive(:log)
      expect(redis).to receive(:smove).with('vmpooler__running__p1', 'vmpooler__completed__p1', 'vm1')
      subject.move_vm_queue('p1', 'vm1', 'running', 'completed', 'msg')
    end

    it 'logs msg' do
      allow(redis).to receive(:smove)
      allow(logger).to receive(:log)
      expect(logger).to receive(:log).with('d', "[!] [p1] 'vm1' a msg here")
      subject.move_vm_queue('p1', 'vm1', 'running', 'completed', 'a msg here')
    end
  end

  describe '#clone_vm' do
    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      expect(Thread).to receive(:new).and_yield
    end

    let(:config) {
      YAML.load(<<-EOT
---
:config:
  prefix: "prefix"
:vsphere:
  username: "vcenter_user"
EOT
      )
    }

    let (:folder) { 'vmfolder' }
    let (:folder_object) { double('folder_object') }
    let (:template_name) { pool }
    let (:template) { "template/#{template_name}" }
    let (:datastore) { 'datastore' }
    let (:target) { 'clone_target' }
    let (:vsphere) { double('vsphere') }
    let (:template_folder_object) { double('template_folder_object') }
    let (:template_vm_object) { double('template_vm_object') }
    let (:clone_task) { double('clone_task') }

    context 'no template specified' do
      it 'should raise an error' do
  
        expect{subject.clone_vm(nil,folder,datastore,target,vsphere)}.to raise_error(/Please provide a full path to the template/)
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[!] [] '' failed while preparing to clone with an error: Please provide a full path to the template")

        expect{subject.clone_vm(nil,folder,datastore,target,vsphere)}.to raise_error(RuntimeError)
      end
    end

    context 'a template with no forward slash in the string' do
      it 'should raise an error' do
  
        expect{subject.clone_vm('vm1',folder,datastore,target,vsphere)}.to raise_error(/Please provide a full path to the template/)
      end

      it 'should log a message' do
        expect(logger).to receive(:log).with('s', "[!] [] '' failed while preparing to clone with an error: Please provide a full path to the template")

        expect{subject.clone_vm('vm1',folder,datastore,target,vsphere)}.to raise_error(RuntimeError)
      end
    end

    # Note - It is impossible to get into the following code branch
    # ...
    # if vm['template'].length == 0
    #   fail "Unable to find template '#{vm['template']}'!"
    # end
    # ...

    context "Template name does not match pool name (Implementation Bug)" do
      let (:template_name) { 'template_vm' }

      # The implementaion of clone_vm incorrectly uses the VM Template name instead of the pool name.  The VM Template represents the
      # name of the VM to clone in vSphere whereas pool is the name of the pool in Pooler.  The tests below document the behaviour of
      # clone_vm if the Template and Pool name differ.  It is expected that these test will fail once this bug is removed.

      context 'a valid template' do
        before(:each) do
          expect(template_folder_object).to receive(:find).with(template_name).and_return(template_vm_object)
          expect(vsphere).to receive(:find_folder).with('template').and_return(template_folder_object)
        end

        context 'with no errors during cloning' do
          before(:each) do
            expect(vsphere).to receive(:find_least_used_host).with(target).and_return('least_used_host')
            expect(vsphere).to receive(:find_datastore).with(datastore).and_return('datastore')
            expect(vsphere).to receive(:find_folder).with('vmfolder').and_return(folder_object)
            expect(template_vm_object).to receive(:CloneVM_Task).and_return(clone_task)
            expect(clone_task).to receive(:wait_for_completion)
            expect(metrics).to receive(:timing).with(/clone\./,/0/)
          end

          it 'should create a cloning VM' do
            expect(logger).to receive(:log).at_least(:once)
            expect(redis.scard("vmpooler__pending__#{pool}")).to eq(0)

            subject.clone_vm(template,folder,datastore,target,vsphere)

            expect(redis.scard("vmpooler__pending__#{template_name}")).to eq(1)
            # Get the new VM Name from the pending pool queue as it should be the only entry
            vm_name = redis.smembers("vmpooler__pending__#{template_name}")[0]
            expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone')).to_not be_nil
            expect(redis.hget("vmpooler__vm__#{vm_name}", 'template')).to eq(template_name)
            expect(redis.hget("vmpooler__clone__#{Date.today.to_s}", "#{template_name}:#{vm_name}")).to_not be_nil
            expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone_time')).to_not be_nil
          end

          it 'should log a message that is being cloned from a template' do
            expect(logger).to receive(:log).with('d',/\[ \] \[#{template_name}\] '(.+)' is being cloned from '#{template_name}'/)
            allow(logger).to receive(:log)

            subject.clone_vm(template,folder,datastore,target,vsphere)
          end

          it 'should log a message that it completed being cloned' do
            expect(logger).to receive(:log).with('s',/\[\+\] \[#{template_name}\] '(.+)' cloned from '#{template_name}' in [0-9.]+ seconds/)
            allow(logger).to receive(:log)

            subject.clone_vm(template,folder,datastore,target,vsphere)
          end
        end

        # An error can be cause by the following configuration errors:
        # - Missing or invalid datastore
        # - Missing or invalid clone target
        # also any runtime errors during the cloning process
        # https://www.vmware.com/support/developer/converter-sdk/conv50_apireference/vim.VirtualMachine.html#clone
        context 'with an error during cloning' do
          before(:each) do
            expect(vsphere).to receive(:find_least_used_host).with(target).and_return('least_used_host')
            expect(vsphere).to receive(:find_datastore).with(datastore).and_return(nil)
            expect(vsphere).to receive(:find_folder).with('vmfolder').and_return(folder_object)
            expect(template_vm_object).to receive(:CloneVM_Task).and_return(clone_task)
            expect(clone_task).to receive(:wait_for_completion).and_raise(RuntimeError,'SomeError')
            expect(metrics).to receive(:timing).with(/clone\./,/0/).exactly(0).times

          end

          it 'should raise an error within the Thread' do
            expect(logger).to receive(:log).at_least(:once)
            expect{subject.clone_vm(template,folder,datastore,target,vsphere)}.to raise_error(/SomeError/)
          end

          it 'should log a message that is being cloned from a template' do
            expect(logger).to receive(:log).with('d',/\[ \] \[#{template_name}\] '(.+)' is being cloned from '#{template_name}'/)
            allow(logger).to receive(:log)

            # Swallow the error
            begin
              subject.clone_vm(template,folder,datastore,target,vsphere)
            rescue
            end
          end

          it 'should log messages that the clone failed' do
            expect(logger).to receive(:log).with('s', /\[!\] \[#{template_name}\] '(.+)' clone failed with an error: SomeError/)
            expect(logger).to receive(:log).with('s', /\[!\] \[#{template_name}\] '(.+)' failed while preparing to clone with an error: SomeError/)
            allow(logger).to receive(:log)

            # Swallow the error
            begin
              subject.clone_vm(template,folder,datastore,target,vsphere)
            rescue
            end
          end
        end
      end
    end

    context 'a valid template' do
      before(:each) do
        expect(template_folder_object).to receive(:find).with(template_name).and_return(template_vm_object)
        expect(vsphere).to receive(:find_folder).with('template').and_return(template_folder_object)
      end

      context 'with no errors during cloning' do
        before(:each) do
          expect(vsphere).to receive(:find_least_used_host).with(target).and_return('least_used_host')
          expect(vsphere).to receive(:find_datastore).with(datastore).and_return('datastore')
          expect(vsphere).to receive(:find_folder).with('vmfolder').and_return(folder_object)
          expect(template_vm_object).to receive(:CloneVM_Task).and_return(clone_task)
          expect(clone_task).to receive(:wait_for_completion)
          expect(metrics).to receive(:timing).with(/clone\./,/0/)
        end

        it 'should create a cloning VM' do
          expect(logger).to receive(:log).at_least(:once)
          expect(redis.scard("vmpooler__pending__#{pool}")).to eq(0)

          subject.clone_vm(template,folder,datastore,target,vsphere)

          expect(redis.scard("vmpooler__pending__#{pool}")).to eq(1)
          # Get the new VM Name from the pending pool queue as it should be the only entry
          vm_name = redis.smembers("vmpooler__pending__#{pool}")[0]
          expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone')).to_not be_nil
          expect(redis.hget("vmpooler__vm__#{vm_name}", 'template')).to eq(template_name)
          expect(redis.hget("vmpooler__clone__#{Date.today.to_s}", "#{pool}:#{vm_name}")).to_not be_nil
          expect(redis.hget("vmpooler__vm__#{vm_name}", 'clone_time')).to_not be_nil
        end

        it 'should decrement the clone tasks counter' do
          redis.incr('vmpooler__tasks__clone')
          redis.incr('vmpooler__tasks__clone')
          expect(redis.get('vmpooler__tasks__clone')).to eq('2')
          subject.clone_vm(template,folder,datastore,target,vsphere)
          expect(redis.get('vmpooler__tasks__clone')).to eq('1')
        end

        it 'should log a message that is being cloned from a template' do
          expect(logger).to receive(:log).with('d',/\[ \] \[#{pool}\] '(.+)' is being cloned from '#{template_name}'/)
          allow(logger).to receive(:log)

          subject.clone_vm(template,folder,datastore,target,vsphere)
        end

        it 'should log a message that it completed being cloned' do
          expect(logger).to receive(:log).with('s',/\[\+\] \[#{pool}\] '(.+)' cloned from '#{template_name}' in [0-9.]+ seconds/)
          allow(logger).to receive(:log)

          subject.clone_vm(template,folder,datastore,target,vsphere)
        end
      end

      # An error can be cause by the following configuration errors:
      # - Missing or invalid datastore
      # - Missing or invalid clone target
      # also any runtime errors during the cloning process
      # https://www.vmware.com/support/developer/converter-sdk/conv50_apireference/vim.VirtualMachine.html#clone
      context 'with an error during cloning' do
        before(:each) do
          expect(vsphere).to receive(:find_least_used_host).with(target).and_return('least_used_host')
          expect(vsphere).to receive(:find_datastore).with(datastore).and_return(nil)
          expect(vsphere).to receive(:find_folder).with('vmfolder').and_return(folder_object)
          expect(template_vm_object).to receive(:CloneVM_Task).and_return(clone_task)
          expect(clone_task).to receive(:wait_for_completion).and_raise(RuntimeError,'SomeError')
          expect(metrics).to receive(:timing).with(/clone\./,/0/).exactly(0).times

        end

        it 'should raise an error within the Thread' do
          expect(logger).to receive(:log).at_least(:once)
          expect{subject.clone_vm(template,folder,datastore,target,vsphere)}.to raise_error(/SomeError/)
        end

        it 'should log a message that is being cloned from a template' do
          expect(logger).to receive(:log).with('d',/\[ \] \[#{pool}\] '(.+)' is being cloned from '#{template_name}'/)
          allow(logger).to receive(:log)

          # Swallow the error
          begin
            subject.clone_vm(template,folder,datastore,target,vsphere)
          rescue
          end
        end

        it 'should log messages that the clone failed' do
          expect(logger).to receive(:log).with('s', /\[!\] \[#{pool}\] '(.+)' clone failed with an error: SomeError/)
          expect(logger).to receive(:log).with('s', /\[!\] \[#{pool}\] '(.+)' failed while preparing to clone with an error: SomeError/)
          allow(logger).to receive(:log)

          # Swallow the error
          begin
            subject.clone_vm(template,folder,datastore,target,vsphere)
          rescue
          end
        end
      end
    end
  end

  describe "#destroy_vm" do
    let (:vsphere) { double('vsphere') }

    let(:config) {
      YAML.load(<<-EOT
---
:redis:
  data_ttl: 168
EOT
      )
    }

    before do
      expect(subject).not_to be_nil
    end

    before(:each) do
      expect(Thread).to receive(:new).and_yield

      create_completed_vm(vm,pool,true)
    end

    context 'when redis data_ttl is not specified in the configuration' do
      let(:config) {
        YAML.load(<<-EOT
---
:redis:
  "key": "value"
EOT
      )
      }

      before(:each) do
        expect(vsphere).to receive(:find_vm).and_return(nil)
      end

      it 'should call redis expire with 0' do
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to_not be_nil
        subject.destroy_vm(vm,pool,vsphere)
        expect(redis.hget("vmpooler__vm__#{vm}", 'checkout')).to be_nil
      end
    end

    context 'when there is no redis section in the configuration' do
      let(:config) {}
      
      it 'should raise an error' do
        expect{ subject.destroy_vm(vm,pool,vsphere) }.to raise_error(NoMethodError)
      end
    end

    context 'when a VM does not exist' do
      before(:each) do
        expect(vsphere).to receive(:find_vm).and_return(nil)
      end

      it 'should not call any vsphere methods' do
        subject.destroy_vm(vm,pool,vsphere)
      end
    end

    context 'when a VM exists' do
      let (:destroy_task) { double('destroy_task') }
      let (:poweroff_task) { double('poweroff_task') }

      before(:each) do
        expect(vsphere).to receive(:find_vm).and_return(host)
        allow(host).to receive(:runtime).and_return(true)
      end

      context 'and an error occurs during destroy' do
        before(:each) do
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOff')
          expect(host).to receive(:Destroy_Task).and_return(destroy_task)
          expect(destroy_task).to receive(:wait_for_completion).and_raise(RuntimeError,'DestroyFailure')
          expect(metrics).to receive(:timing).exactly(0).times
        end

        it 'should raise an error in the thread' do
          expect { subject.destroy_vm(vm,pool,vsphere) }.to raise_error(/DestroyFailure/)
        end
      end

      context 'and an error occurs during power off' do
        before(:each) do
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOn')
          expect(host).to receive(:PowerOffVM_Task).and_return(poweroff_task)
          expect(poweroff_task).to receive(:wait_for_completion).and_raise(RuntimeError,'PowerOffFailure')
          expect(logger).to receive(:log).with('d', "[ ] [#{pool}] '#{vm}' is being shut down")
          expect(metrics).to receive(:timing).exactly(0).times
        end

        it 'should raise an error in the thread' do
          expect { subject.destroy_vm(vm,pool,vsphere) }.to raise_error(/PowerOffFailure/)
        end
      end

      context 'and is powered off' do
        before(:each) do
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOff')
          expect(host).to receive(:Destroy_Task).and_return(destroy_task)
          expect(destroy_task).to receive(:wait_for_completion)
          expect(metrics).to receive(:timing).with("destroy.#{pool}", /0/)
        end

        it 'should log a message the VM was destroyed' do
          expect(logger).to receive(:log).with('s', /\[-\] \[#{pool}\] '#{vm}' destroyed in [0-9.]+ seconds/)
          subject.destroy_vm(vm,pool,vsphere)
        end
      end

      context 'and is powered on' do
        before(:each) do
          allow(host).to receive_message_chain(:runtime, :powerState).and_return('poweredOn')
          expect(host).to receive(:Destroy_Task).and_return(destroy_task)
          expect(host).to receive(:PowerOffVM_Task).and_return(poweroff_task)
          expect(poweroff_task).to receive(:wait_for_completion)
          expect(destroy_task).to receive(:wait_for_completion)
          expect(metrics).to receive(:timing).with("destroy.#{pool}", /0/)
        end

        it 'should log a message the VM is being shutdown' do
          expect(logger).to receive(:log).with('d', "[ ] [#{pool}] '#{vm}' is being shut down")
          allow(logger).to receive(:log)

          subject.destroy_vm(vm,pool,vsphere)
        end

        it 'should log a message the VM was destroyed' do
         expect(logger).to receive(:log).with('s', /\[-\] \[#{pool}\] '#{vm}' destroyed in [0-9.]+ seconds/)
          allow(logger).to receive(:log)

          subject.destroy_vm(vm,pool,vsphere)
        end
      end
    end
  end

  describe '#_check_pool' do
    let(:pool_helper) { double('pool') }
    let(:vsphere) { {pool => pool_helper} }
    let(:config) { {
      config: { task_limit: 10 },
      pools: [ {'name' => 'pool1', 'size' => 5} ]
    } }

    before do
      expect(subject).not_to be_nil
      $vsphere = vsphere
      allow(logger).to receive(:log)
      allow(pool_helper).to receive(:find_folder)
      allow(redis).to receive(:smembers).with('vmpooler__pending__pool1').and_return([])
      allow(redis).to receive(:smembers).with('vmpooler__ready__pool1').and_return([])
      allow(redis).to receive(:smembers).with('vmpooler__running__pool1').and_return([])
      allow(redis).to receive(:smembers).with('vmpooler__completed__pool1').and_return([])
      allow(redis).to receive(:smembers).with('vmpooler__discovered__pool1').and_return([])
      allow(redis).to receive(:smembers).with('vmpooler__migrating__pool1').and_return([])
      allow(redis).to receive(:set)
      allow(redis).to receive(:get).with('vmpooler__tasks__clone').and_return(0)
      allow(redis).to receive(:get).with('vmpooler__empty__pool1').and_return(nil)
    end

    context 'logging' do
      it 'logs empty pool' do
        allow(redis).to receive(:scard).with('vmpooler__pending__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__ready__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__running__pool1').and_return(0)

        expect(logger).to receive(:log).with('s', "[!] [pool1] is empty")
        subject._check_pool(config[:pools][0], vsphere)
      end
    end
  end

  describe '#_stats_running_ready' do
    let(:pool_helper) { double('pool') }
    let(:vsphere) { {pool => pool_helper} }
    let(:metrics) { Vmpooler::DummyStatsd.new }
    let(:config) { {
      config: { task_limit: 10 },
      pools: [ {'name' => 'pool1', 'size' => 5} ],
      graphite: { 'prefix' => 'vmpooler' }
    } }

    before do
      expect(subject).not_to be_nil
      $vsphere = vsphere
      allow(logger).to receive(:log)
      allow(pool_helper).to receive(:find_folder)
      allow(redis).to receive(:smembers).and_return([])
      allow(redis).to receive(:set)
      allow(redis).to receive(:get).with('vmpooler__tasks__clone').and_return(0)
      allow(redis).to receive(:get).with('vmpooler__empty__pool1').and_return(nil)
    end

    context 'metrics' do
      subject { Vmpooler::PoolManager.new(config, logger, redis, metrics) }

      it 'increments metrics' do
        allow(redis).to receive(:scard).with('vmpooler__ready__pool1').and_return(1)
        allow(redis).to receive(:scard).with('vmpooler__cloning__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__pending__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__running__pool1').and_return(5)

        expect(metrics).to receive(:gauge).with('ready.pool1', 1)
        expect(metrics).to receive(:gauge).with('running.pool1', 5)
        subject._check_pool(config[:pools][0], vsphere)
      end

      it 'increments metrics when ready with 0 when pool empty' do
        allow(redis).to receive(:scard).with('vmpooler__ready__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__cloning__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__pending__pool1').and_return(0)
        allow(redis).to receive(:scard).with('vmpooler__running__pool1').and_return(5)

        expect(metrics).to receive(:gauge).with('ready.pool1', 0)
        expect(metrics).to receive(:gauge).with('running.pool1', 5)
        subject._check_pool(config[:pools][0], vsphere)
      end
    end
  end

  describe '#_create_vm_snapshot' do
    let(:snapshot_manager) { 'snapshot_manager' }
    let(:pool_helper) { double('snapshot_manager') }
    let(:vsphere) { {snapshot_manager => pool_helper} }

    before do
      expect(subject).not_to be_nil
      $vsphere = vsphere
    end

    context '(valid host)' do
      let(:vm_host) { double('vmhost') }

      it 'creates a snapshot' do
        expect(vsphere).to receive(:find_vm).and_return vm_host
        expect(logger).to receive(:log)
        expect(vm_host).to receive_message_chain(:CreateSnapshot_Task, :wait_for_completion)
        expect(redis).to receive(:hset).with('vmpooler__vm__testvm', 'snapshot:testsnapshot', Time.now.to_s)
        expect(logger).to receive(:log)

        subject._create_vm_snapshot('testvm', 'testsnapshot', vsphere)
      end
    end
  end

  describe '#_revert_vm_snapshot' do
    let(:snapshot_manager) { 'snapshot_manager' }
    let(:pool_helper) { double('snapshot_manager') }
    let(:vsphere) { {snapshot_manager => pool_helper} }

    before do
      expect(subject).not_to be_nil
      $vsphere = vsphere
    end

    context '(valid host)' do
      let(:vm_host) { double('vmhost') }
      let(:vm_snapshot) { double('vmsnapshot') }

      it 'reverts a snapshot' do
        expect(vsphere).to receive(:find_vm).and_return vm_host
        expect(vsphere).to receive(:find_snapshot).and_return vm_snapshot
        expect(logger).to receive(:log)
        expect(vm_snapshot).to receive_message_chain(:RevertToSnapshot_Task, :wait_for_completion)
        expect(logger).to receive(:log)

        subject._revert_vm_snapshot('testvm', 'testsnapshot', vsphere)
      end
    end
  end

  describe '#_check_snapshot_queue' do
    let(:pool_helper) { double('pool') }
    let(:vsphere) { {pool => pool_helper} }

    before do
      expect(subject).not_to be_nil
      $vsphere = vsphere
    end

    it 'checks appropriate redis queues' do
      expect(redis).to receive(:spop).with('vmpooler__tasks__snapshot')
      expect(redis).to receive(:spop).with('vmpooler__tasks__snapshot-revert')

      subject._check_snapshot_queue(vsphere)
    end
  end
end
